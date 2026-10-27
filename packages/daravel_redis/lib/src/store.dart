import 'dart:convert';
import 'dart:math';

import 'package:daravel/daravel.dart';

import 'client.dart';
import 'resp.dart';
import 'serializer.dart';

/// `CACHE_STORE=redis`: a cache, locks and rate limits shared by every
/// server (scope `cluster`).
///
/// Numbers are stored as they are (so `INCRBY` works on them and Laravel
/// reads them), anything else as JSON or, with [RedisSerializer.php], as
/// Laravel's `serialize()` writes it; both are read. Locks are Laravel's
/// `RedisLock`:
/// `SET name owner NX PX` and a release that checks the owner. Reads fail
/// open (a dropped connection is a miss); writes and locks throw.
final class RedisStore
    implements TouchableCacheStore, WindowCounterStore, RateCounterStore {
  RedisStore(
    this.client, {
    RedisClient? lockClient,
    this.prefix = '',
    this.flushPrefix = '',
    this.serializer = RedisSerializer.json,
  }) : lockClient = lockClient ?? client;

  /// How values that are not numbers are written (`REDIS_SERIALIZER`).
  final RedisSerializer serializer;

  final RedisClient client;

  /// Where locks live: Laravel keeps them on the `default` connection
  /// (`lock_connection`), apart from the cache's database.
  final RedisClient lockClient;

  /// Put before every key (`REDIS_PREFIX`).
  final String prefix;

  /// What [flush] deletes, after [prefix]: the cache's own prefix
  /// (`CACHE_PREFIX`), so it never takes queues or other data with it.
  final String flushPrefix;

  @override
  StateScope get scope => StateScope.cluster;

  String _key(String key) => '$prefix$key';

  /// Laravel's `RedisLock` key: the connection prefix, then the lock's name
  /// (which carries the cache prefix), so both frameworks see one lock.
  String _lock(String name) => '$prefix$name';

  /// The key [key] has in Redis, after [prefix].
  String keyOf(String key) => _key(key);

  /// Numbers as they are, as Laravel's `RedisStore` does (`is_numeric`).
  String encode(Object? value) => switch (value) {
    final int number => '$number',
    final double number when number.isFinite => '$number',
    _ => switch (serializer) {
      RedisSerializer.json => jsonEncode(value),
      RedisSerializer.php => PhpSerializer.encode(value),
    },
  };

  /// A value written by Daravel (JSON) or Laravel (`serialize()`), or the
  /// raw text when it is neither.
  static Object? decode(String? raw) {
    if (raw == null) {
      return null;
    }
    try {
      return PhpSerializer.looksSerialized(raw)
          ? PhpSerializer.decode(raw)
          : jsonDecode(raw);
    } on FormatException {
      return raw;
    }
  }

  @override
  Future<Object?> get(String key) async {
    try {
      return decode(await client.get(_key(key)));
    } on RedisConnectionException {
      return null;
    }
  }

  @override
  Future<Map<String, Object?>> many(List<String> keys) async {
    if (keys.isEmpty) {
      return const {};
    }
    List<Object?> values;
    try {
      values = (await client.command(['MGET', ...keys.map(_key)]))! as List;
    } on RedisConnectionException {
      values = List.filled(keys.length, null);
    }
    return {
      for (var i = 0; i < keys.length; i++)
        keys[i]: decode(values[i] as String?),
    };
  }

  @override
  Future<void> put(String key, Object? value, {Duration? ttl}) =>
      client.set(_key(key), encode(value), ttl: ttl);

  @override
  Future<void> putMany(Map<String, Object?> values, {Duration? ttl}) =>
      Future.wait([
        for (final MapEntry(:key, :value) in values.entries)
          put(key, value, ttl: ttl),
      ]);

  @override
  Future<bool> add(String key, Object? value, {Duration? ttl}) =>
      client.set(_key(key), encode(value), ttl: ttl, onlyIfAbsent: true);

  @override
  Future<int> increment(String key, [int by = 1]) async =>
      (await client.command(['INCRBY', _key(key), by]))! as int;

  @override
  Future<int> decrement(String key, [int by = 1]) async =>
      (await client.command(['DECRBY', _key(key), by]))! as int;

  @override
  Future<void> forever(String key, Object? value) => put(key, value);

  @override
  Future<bool> forget(String key) async => await client.del([_key(key)]) > 0;

  /// Deletes this cache's keys only (`SCAN` and `UNLINK` in batches, on
  /// every master of a cluster), never the whole database as Laravel's
  /// `FLUSHDB` does.
  @override
  Future<void> flush() async {
    final batch = <String>[];
    await for (final key in client.scan(
      match: '${_escape('$prefix$flushPrefix')}*',
    )) {
      batch.add(key);
      if (batch.length >= 500) {
        await client.command(['UNLINK', ...batch]);
        batch.clear();
      }
    }
    if (batch.isNotEmpty) {
      await client.command(['UNLINK', ...batch]);
    }
  }

  /// [text] with the glob characters of `SCAN MATCH` escaped.
  static String _escape(String text) =>
      text.replaceAllMapped(RegExp(r'[*?\[\]\\]'), (m) => '\\${m[0]}');

  @override
  Future<bool> touch(String key, Duration ttl) async =>
      await client.command([
        'PEXPIRE',
        _key(key),
        max(1, ttl.inMilliseconds),
      ]) ==
      1;

  // -------------------------------------------------------------------
  // Locks (Laravel's RedisLock).

  static final RedisScript _release = RedisScript('''
if redis.call('GET', KEYS[1]) == ARGV[1] then
  return redis.call('DEL', KEYS[1])
else
  return 0
end''');

  @override
  Future<bool> acquireLock(String name, String owner, Duration ttl) =>
      lockClient.set(_lock(name), owner, ttl: ttl, onlyIfAbsent: true);

  @override
  Future<bool> releaseLock(String name, String owner) async =>
      await lockClient.eval(_release, keys: [_lock(name)], args: [owner]) == 1;

  @override
  Future<void> forceReleaseLock(String name) => lockClient.del([_lock(name)]);

  @override
  Future<String?> lockOwner(String name) => lockClient.get(_lock(name));

  // -------------------------------------------------------------------
  // Rate limits: one round trip per attempt.

  /// Counts a hit unless the window is full; the window starts with its
  /// first hit and its key expires with it.
  static final RedisScript _hit = RedisScript('''
local max = tonumber(ARGV[1])
local hits = tonumber(redis.call('GET', KEYS[1]) or '0')
if hits >= max then
  return {0, hits, redis.call('PTTL', KEYS[1])}
end
hits = redis.call('INCR', KEYS[1])
if hits == 1 then
  redis.call('PEXPIRE', KEYS[1], ARGV[2])
end
return {1, hits, redis.call('PTTL', KEYS[1])}''');

  @override
  Future<({bool allowed, int hits, DateTime resetAt})> hitWindow(
    String key,
    int maxHits,
    Duration window,
  ) async {
    final reply =
        (await client.eval(
              _hit,
              keys: [_key(key)],
              args: [maxHits, max(1, window.inMilliseconds)],
            ))!
            as List;
    return (
      allowed: reply[0] == 1,
      hits: reply[1]! as int,
      resetAt: _resetAt(reply[2]! as int, window),
    );
  }

  @override
  Future<({int hits, DateTime resetAt})?> currentWindow(String key) async {
    final (raw, ttl) = await (
      client.get(_key(key)),
      client.command(['PTTL', _key(key)]),
    ).wait;
    if (raw == null) {
      return null;
    }
    return (
      hits: int.tryParse(raw) ?? 0,
      resetAt: _resetAt(ttl! as int, Duration.zero),
    );
  }

  /// A sliding window in one hash: a field per window, the previous one
  /// weighted by how much of it the window still covers. Time is the
  /// server's (`TIME`), so servers with drifting clocks agree.
  static final RedisScript _sliding = RedisScript('''
if redis.replicate_commands then redis.replicate_commands() end
local t = redis.call('TIME')
local now = tonumber(t[1]) * 1000 + math.floor(tonumber(t[2]) / 1000)
local max = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local index = math.floor(now / window)
local current = tonumber(redis.call('HGET', KEYS[1], index) or '0')
local previous = tonumber(redis.call('HGET', KEYS[1], index - 1) or '0')
local elapsed = now - index * window
local count = previous * (window - elapsed) / window + current
if count + 1 > max then
  local wait
  if current + 1 > max then
    -- Into the next window, until this one weighs little enough.
    wait = window - elapsed + math.ceil(window * (1 - (max - 1) / current))
  else
    -- Later in this window, until the previous one weighs little enough.
    wait = math.ceil(window - (max - current - 1) * window / previous - elapsed)
  end
  if wait < 1 then wait = 1 end
  return {0, 0, 2 * window - elapsed, wait}
end
redis.call('HINCRBY', KEYS[1], index, 1)
redis.call('HDEL', KEYS[1], index - 2)
redis.call('PEXPIRE', KEYS[1], 2 * window)
return {1, math.floor(max - count - 1), 2 * window - elapsed, 0}''');

  /// GCRA: the key holds the theoretical arrival time of the next hit; a
  /// hit passes when that is at most one window ahead of now.
  static final RedisScript _gcra = RedisScript(
    '''
if redis.replicate_commands then redis.replicate_commands() end
local t = redis.call('TIME')
local now = tonumber(t[1]) * 1000 + tonumber(t[2]) / 1000
local max = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local interval = window / max
local tat = tonumber(redis.call('GET', KEYS[1]) or '0')
if tat < now then tat = now end
local next = tat + interval
local allowAt = next - window
if allowAt > now then
  return {0, 0, math.ceil(tat - now), math.ceil(allowAt - now)}
end
redis.call('SET', KEYS[1], string.format('%.3f', next), 'PX', math.ceil(next - now))
return {1, math.floor((now - allowAt) / interval), math.ceil(next - now), 0}''',
  );

  ({bool allowed, int remaining, Duration resetIn, Duration retryAfter})
  _counted(Object? reply) {
    final [allowed, remaining, resetIn, retryAfter] = (reply! as List)
        .cast<int>();
    return (
      allowed: allowed == 1,
      remaining: max(0, remaining),
      resetIn: Duration(milliseconds: max(0, resetIn)),
      retryAfter: Duration(milliseconds: max(0, retryAfter)),
    );
  }

  @override
  Future<({bool allowed, int remaining, Duration resetIn, Duration retryAfter})>
  hitSlidingWindow(String key, int maxHits, Duration window) async => _counted(
    await client.eval(
      _sliding,
      keys: [_key(key)],
      args: [maxHits, max(1, window.inMilliseconds)],
    ),
  );

  @override
  Future<({bool allowed, int remaining, Duration resetIn, Duration retryAfter})>
  hitGcra(String key, int maxHits, Duration window) async => _counted(
    await client.eval(
      _gcra,
      keys: [_key(key)],
      args: [maxHits, max(1, window.inMilliseconds)],
    ),
  );

  /// The window's end from the key's time to live (`PTTL`: -1 without one,
  /// -2 when gone).
  static DateTime _resetAt(int ttlMs, Duration window) => Clock.now()
      .toUtc()
      .add(ttlMs >= 0 ? Duration(milliseconds: ttlMs) : window);
}
