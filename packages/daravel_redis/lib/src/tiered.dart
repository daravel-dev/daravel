import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:daravel/daravel.dart';

import 'client.dart';
import 'connection.dart';
import 'resp.dart';
import 'store.dart';

/// Keys written under [prefix], as Redis reports them (`CLIENT TRACKING`
/// in broadcast mode, RESP3): one connection per master, opened on first
/// use and again after it drops.
///
/// [onInvalidate] receives the keys written elsewhere (null: all of them,
/// after `FLUSHDB`); [onReset] runs whenever tracking starts or stops, since
/// writes in between were not reported.
final class RedisInvalidations {
  RedisInvalidations(
    this.client, {
    required this.prefix,
    required this.onInvalidate,
    required this.onReset,
  });

  final RedisClient client;
  final String prefix;
  final void Function(List<String>? keys) onInvalidate;
  final void Function() onReset;

  bool _started = false;
  bool _live = false;

  /// Why tracking is unavailable (a server without RESP3 or `CLIENT
  /// TRACKING`), when it is.
  String? unsupported;

  /// Whether every master reports writes now.
  bool get live => _live;

  /// Starts tracking, once.
  void start() {
    if (_started) {
      return;
    }
    _started = true;
    unawaited(_run());
  }

  Future<void> _run() async {
    var backoff = const Duration(milliseconds: 100);
    final random = Random();
    while (!client.isClosed && unsupported == null) {
      final connections = <RedisConnection>[];
      Timer? keepAlive;
      try {
        for (final master in await client.masterClients()) {
          final connection = await master.dedicated(onMessage: _onPush);
          connections.add(connection);
          await connection.send(['HELLO', 3]);
          await connection.send([
            'CLIENT',
            'TRACKING',
            'ON',
            'BCAST',
            'PREFIX',
            prefix,
          ]);
        }
        _live = true;
        onReset();
        backoff = const Duration(milliseconds: 100);
        // An idle connection would not notice a server that vanished.
        keepAlive = Timer.periodic(const Duration(seconds: 5), (_) {
          for (final connection in connections) {
            unawaited(
              connection.send(['PING']).then<void>((_) {}, onError: (_) {}),
            );
          }
        });
        await Future.any([for (final c in connections) c.done]);
      } on RedisCommandException catch (error) {
        // HELLO or CLIENT TRACKING refused: Redis before 6, or a proxy.
        unsupported = error.message;
      } on Object {
        // Reconnect below.
      } finally {
        keepAlive?.cancel();
        if (_live) {
          _live = false;
          onReset();
        }
        for (final connection in connections) {
          await connection.close();
        }
      }
      if (client.isClosed || unsupported != null) {
        return;
      }
      await Future<void>.delayed(
        Duration(milliseconds: random.nextInt(backoff.inMilliseconds + 1)),
      );
      backoff = Duration(milliseconds: min(5000, backoff.inMilliseconds * 2));
    }
  }

  void _onPush(List<Object?> push) {
    if (push case ['invalidate', final Object? keys]) {
      onInvalidate(keys is List ? keys.whereType<String>().toList() : null);
    }
  }
}

final class _Entry {
  _Entry(this.value, this.expiresAt);

  final Object? value;
  final DateTime expiresAt;
}

/// `CACHE_STORE=tiered`: a cache in each isolate's memory (L1) in front of
/// Redis (L2), kept exact by Redis itself: a write from any server reaches
/// every L1 as an invalidation (`CLIENT TRACKING ... BCAST`), so a read
/// from L1 never returns a value older than the last write it was told of.
///
/// Its values live under their own prefix (`tiered:`), so only they are
/// broadcast. Locks and rate limits go to [shared] (the `redis` store).
/// Until tracking runs (or where the server lacks it, before Redis 6),
/// every read goes to Redis. An L1 entry lives at most [maxAge], and at
/// most [maxKeys] are kept, the least recently read evicted first.
final class TieredStore
    implements TouchableCacheStore, WindowCounterStore, RateCounterStore {
  TieredStore(
    this.values, {
    required this.shared,
    this.maxKeys = 10000,
    this.maxAge = const Duration(seconds: 60),
  }) {
    invalidations = RedisInvalidations(
      values.client,
      prefix: values.keyOf(''),
      onInvalidate: _invalidate,
      onReset: _reset,
    );
  }

  /// The values, in Redis.
  final RedisStore values;

  /// Locks and rate limits.
  final RedisStore shared;
  final int maxKeys;
  final Duration maxAge;
  late final RedisInvalidations invalidations;

  final LinkedHashMap<String, _Entry> _l1 = LinkedHashMap();

  /// Reads waiting for Redis, by key, and the keys written meanwhile.
  final Map<String, int> _reads = {};
  final Set<String> _dirty = {};

  /// Changes whenever tracking starts or stops.
  int _session = 0;
  int _hits = 0;
  int _misses = 0;

  @override
  StateScope get scope => StateScope.cluster;

  /// Entries in this isolate's L1, whether tracking is live, and why not.
  Map<String, Object?> get stats => {
    'entries': _l1.length,
    'hits': _hits,
    'misses': _misses,
    'live': invalidations.live,
    if (invalidations.unsupported case final String reason)
      'unsupported': reason,
  };

  void _invalidate(List<String>? keys) {
    if (keys == null) {
      _l1.clear();
      _dirty.addAll(_reads.keys);
      return;
    }
    keys.forEach(_drop);
  }

  void _reset() {
    _session++;
    _l1.clear();
    _dirty.addAll(_reads.keys);
  }

  void _drop(String full) {
    _l1.remove(full);
    if (_reads.containsKey(full)) {
      _dirty.add(full);
    }
  }

  @override
  Future<Object?> get(String key) async {
    invalidations.start();
    final full = values.keyOf(key);
    if (invalidations.live) {
      final entry = _l1.remove(full);
      // L1 shadows Redis's own expiry, which runs on real time.
      if (entry != null && entry.expiresAt.isAfter(DateTime.now())) {
        _l1[full] = entry; // most recently read last
        _hits++;
        return entry.value;
      }
    }
    return _load(full);
  }

  Future<Object?> _load(String full) async {
    _misses++;
    final session = _session;
    _reads.update(full, (n) => n + 1, ifAbsent: () => 1);
    try {
      final List<Object?> replies;
      try {
        replies = await values.client.pipeline([
          ['GET', full],
          ['PTTL', full],
        ]);
      } on RedisConnectionException {
        return null; // fail open, as the redis store
      }
      final [raw, ttl] = replies;
      if (raw is RedisCommandException) {
        throw raw;
      }
      final value = RedisStore.decode(raw as String?);
      if (raw != null &&
          invalidations.live &&
          session == _session &&
          !_dirty.contains(full)) {
        final left = ttl is int && ttl > 0
            ? Duration(milliseconds: ttl)
            : maxAge;
        _l1[full] = _Entry(
          value,
          DateTime.now().add(left < maxAge ? left : maxAge),
        );
        while (_l1.length > maxKeys) {
          _l1.remove(_l1.keys.first);
        }
      }
      return value;
    } finally {
      final left = _reads[full]! - 1;
      if (left == 0) {
        _reads.remove(full);
        _dirty.remove(full);
      } else {
        _reads[full] = left;
      }
    }
  }

  Future<T> _write<T>(String key, Future<T> Function() write) async {
    final full = values.keyOf(key);
    _drop(full);
    try {
      return await write();
    } finally {
      _drop(full);
    }
  }

  @override
  Future<Map<String, Object?>> many(List<String> keys) async {
    final found = await Future.wait(keys.map(get));
    return {for (var i = 0; i < keys.length; i++) keys[i]: found[i]};
  }

  @override
  Future<void> put(String key, Object? value, {Duration? ttl}) =>
      _write(key, () => values.put(key, value, ttl: ttl));

  @override
  Future<void> putMany(Map<String, Object?> values, {Duration? ttl}) =>
      Future.wait([
        for (final MapEntry(:key, :value) in values.entries)
          put(key, value, ttl: ttl),
      ]);

  @override
  Future<bool> add(String key, Object? value, {Duration? ttl}) =>
      _write(key, () => values.add(key, value, ttl: ttl));

  @override
  Future<int> increment(String key, [int by = 1]) =>
      _write(key, () => values.increment(key, by));

  @override
  Future<int> decrement(String key, [int by = 1]) =>
      _write(key, () => values.decrement(key, by));

  @override
  Future<void> forever(String key, Object? value) =>
      _write(key, () => values.forever(key, value));

  @override
  Future<bool> forget(String key) => _write(key, () => values.forget(key));

  @override
  Future<bool> touch(String key, Duration ttl) =>
      _write(key, () => values.touch(key, ttl));

  @override
  Future<void> flush() async {
    _invalidate(null);
    await values.flush();
    _invalidate(null);
  }

  @override
  Future<bool> acquireLock(String name, String owner, Duration ttl) =>
      shared.acquireLock(name, owner, ttl);

  @override
  Future<bool> releaseLock(String name, String owner) =>
      shared.releaseLock(name, owner);

  @override
  Future<void> forceReleaseLock(String name) => shared.forceReleaseLock(name);

  @override
  Future<String?> lockOwner(String name) => shared.lockOwner(name);

  @override
  Future<({bool allowed, int hits, DateTime resetAt})> hitWindow(
    String key,
    int maxHits,
    Duration window,
  ) => shared.hitWindow(key, maxHits, window);

  @override
  Future<({int hits, DateTime resetAt})?> currentWindow(String key) =>
      shared.currentWindow(key);

  @override
  Future<({bool allowed, int remaining, Duration resetIn, Duration retryAfter})>
  hitSlidingWindow(String key, int maxHits, Duration window) =>
      shared.hitSlidingWindow(key, maxHits, window);

  @override
  Future<({bool allowed, int remaining, Duration resetIn, Duration retryAfter})>
  hitGcra(String key, int maxHits, Duration window) =>
      shared.hitGcra(key, maxHits, window);
}
