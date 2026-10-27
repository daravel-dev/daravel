import 'dart:convert';
import 'dart:math';

import 'package:daravel/daravel.dart';

import 'client.dart';
import 'resp.dart';

/// `CACHE_STORE=redis`: a cache, locks and rate limits shared by every
/// server (scope `cluster`).
///
/// Numbers are stored as they are (so `INCRBY` works on them and Laravel
/// reads them), anything else as JSON. Locks are Laravel's `RedisLock`:
/// `SET name owner NX PX` and a release that checks the owner. Reads fail
/// open (a dropped connection is a miss); writes and locks throw.
final class RedisStore implements TouchableCacheStore, WindowCounterStore {
  RedisStore(
    this.client, {
    RedisClient? lockClient,
    this.prefix = '',
    this.flushPrefix = '',
  }) : lockClient = lockClient ?? client;

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

  static String _encode(Object? value) =>
      value is int ? '$value' : jsonEncode(value);

  static Object? _decode(String? raw) {
    if (raw == null) {
      return null;
    }
    try {
      return jsonDecode(raw);
    } on FormatException {
      return raw; // written by something else (Laravel's serialize()).
    }
  }

  @override
  Future<Object?> get(String key) async {
    try {
      return _decode(await client.get(_key(key)));
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
        keys[i]: _decode(values[i] as String?),
    };
  }

  @override
  Future<void> put(String key, Object? value, {Duration? ttl}) =>
      client.set(_key(key), _encode(value), ttl: ttl);

  @override
  Future<void> putMany(Map<String, Object?> values, {Duration? ttl}) =>
      Future.wait([
        for (final MapEntry(:key, :value) in values.entries)
          put(key, value, ttl: ttl),
      ]);

  @override
  Future<bool> add(String key, Object? value, {Duration? ttl}) =>
      client.set(_key(key), _encode(value), ttl: ttl, onlyIfAbsent: true);

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

  /// Deletes this cache's keys only (`SCAN` and `UNLINK` in batches), never
  /// the whole database as Laravel's `FLUSHDB` does.
  @override
  Future<void> flush() async {
    var cursor = '0';
    do {
      final reply =
          (await client.command([
                'SCAN',
                cursor,
                'MATCH',
                '${_escape('$prefix$flushPrefix')}*',
                'COUNT',
                500,
              ]))!
              as List;
      cursor = reply[0]! as String;
      final keys = (reply[1]! as List).cast<String>();
      if (keys.isNotEmpty) {
        await client.command(['UNLINK', ...keys]);
      }
    } while (cursor != '0');
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

  /// The window's end from the key's time to live (`PTTL`: -1 without one,
  /// -2 when gone).
  static DateTime _resetAt(int ttlMs, Duration window) => Clock.now()
      .toUtc()
      .add(ttlMs >= 0 ? Duration(milliseconds: ttlMs) : window);
}
