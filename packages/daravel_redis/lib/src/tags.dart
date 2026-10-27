import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:daravel/daravel.dart';

import 'store.dart';

/// Laravel 12's `RedisTaggedCache` and `RedisTagSet`, key for key, so both
/// frameworks read, write and flush the same tagged entries:
///
/// | Key (after `REDIS_PREFIX`) | Holds |
/// | :-- | :-- |
/// | `<cache prefix><sha1>:<key>` | the value; `sha1` of `tag:<a>:entries\|tag:<b>:entries` |
/// | `<cache prefix>tag:<name>:entries` | the tag's keys (`<sha1>:<key>`), by when they expire (zset; -1 for never) |
///
/// A flush deletes every key its tags list and takes them off the lists;
/// [flushStale] drops the expired ones from the lists.
final class RedisTaggedCacheStore implements TaggedCacheStore {
  RedisTaggedCacheStore(this.store, this.names, {this.prefix = ''})
    : _namespace = sha1
          .convert(utf8.encode(names.map((n) => 'tag:$n:entries').join('|')))
          .toString();

  final RedisStore store;
  @override
  final List<String> names;

  /// The cache prefix (`CACHE_PREFIX`).
  final String prefix;
  final String _namespace;

  @override
  StateScope get scope => StateScope.cluster;

  /// A key as the tags' lists hold it (Laravel's `itemKey`).
  String _entry(String key) => '$_namespace:$key';

  /// The tag's list, in the store's key space.
  String _tag(String name) => store.keyOf('${prefix}tag:$name:entries');

  String _value(String key) => '$prefix${_entry(key)}';

  @override
  Future<String> itemKey(String key) async => _value(key);

  /// Lists [key] under every tag, expiring after [ttl] (never when null);
  /// [onlyNew] keeps an expiry already set (`ZADD NX`).
  Future<void> _addEntry(String key, {Duration? ttl, bool onlyNew = false}) {
    final score = ttl == null
        ? -1
        : Clock.now().toUtc().millisecondsSinceEpoch ~/ 1000 +
              (ttl.inMilliseconds / 1000).ceil();
    return Future.wait([
      for (final name in names)
        store.client.command([
          'ZADD',
          _tag(name),
          if (onlyNew) 'NX',
          score,
          _entry(key),
        ]),
    ]);
  }

  @override
  Future<Object?> get(String key) => store.get(_value(key));

  @override
  Future<Map<String, Object?>> many(List<String> keys) async {
    final found = await store.many([for (final key in keys) _value(key)]);
    return {for (final key in keys) key: found[_value(key)]};
  }

  /// Without [ttl], forever; with one of zero or less, a forget (Laravel's
  /// `put`).
  @override
  Future<void> put(String key, Object? value, {Duration? ttl}) async {
    if (ttl == null) {
      return forever(key, value);
    }
    if (ttl <= Duration.zero) {
      await forget(key);
      return;
    }
    await _addEntry(key, ttl: ttl);
    await store.put(_value(key), value, ttl: ttl);
  }

  @override
  Future<void> putMany(Map<String, Object?> values, {Duration? ttl}) =>
      Future.wait([
        for (final MapEntry(:key, :value) in values.entries)
          put(key, value, ttl: ttl),
      ]);

  @override
  Future<bool> add(String key, Object? value, {Duration? ttl}) async {
    if (ttl != null && ttl > Duration.zero) {
      await _addEntry(key, ttl: ttl);
    }
    return store.add(_value(key), value, ttl: ttl);
  }

  @override
  Future<int> increment(String key, [int by = 1]) async {
    await _addEntry(key, onlyNew: true);
    return store.increment(_value(key), by);
  }

  @override
  Future<int> decrement(String key, [int by = 1]) async {
    await _addEntry(key, onlyNew: true);
    return store.decrement(_value(key), by);
  }

  @override
  Future<void> forever(String key, Object? value) async {
    await _addEntry(key);
    await store.forever(_value(key), value);
  }

  @override
  Future<bool> forget(String key) => store.forget(_value(key));

  /// Every key the tags list, deleted 1000 at a time and taken off every
  /// list (Laravel's `flush`; one command per slot in a cluster).
  @override
  Future<void> flush() async {
    final entries = <String>{};
    for (final name in names) {
      var cursor = '0';
      do {
        final reply =
            (await store.client.command([
                  'ZSCAN',
                  _tag(name),
                  cursor,
                  'COUNT',
                  1000,
                ]))!
                as List;
        cursor = reply[0]! as String;
        final pairs = reply[1]! as List;
        for (var i = 0; i < pairs.length; i += 2) {
          entries.add(pairs[i]! as String);
        }
      } while (cursor != '0');
    }
    final all = entries.toList();
    for (var start = 0; start < all.length; start += 1000) {
      final chunk = all.sublist(
        start,
        start + 1000 > all.length ? all.length : start + 1000,
      );
      await store.client.del([
        for (final entry in chunk) store.keyOf('$prefix$entry'),
      ]);
      await Future.wait([
        for (final name in names)
          store.client.command(['ZREM', _tag(name), ...chunk]),
      ]);
    }
  }

  @override
  Future<void> flushStale() => Future.wait([
    for (final name in names)
      store.client.command([
        'ZREMRANGEBYSCORE',
        _tag(name),
        0,
        Clock.now().toUtc().millisecondsSinceEpoch ~/ 1000,
      ]),
  ]);

  @override
  Future<bool> acquireLock(String name, String owner, Duration ttl) =>
      store.acquireLock(name, owner, ttl);

  @override
  Future<bool> releaseLock(String name, String owner) =>
      store.releaseLock(name, owner);

  @override
  Future<void> forceReleaseLock(String name) => store.forceReleaseLock(name);

  @override
  Future<String?> lockOwner(String name) => store.lockOwner(name);
}
