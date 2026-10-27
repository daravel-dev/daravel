import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../server/coordinator.dart';
import 'cache.dart';

/// A store whose entries can carry tags (Laravel's `TaggableStore`):
/// `Cache.tags(['posts']).put(...)`, then `Cache.tags(['posts']).flush()`
/// forgets them. The `memory` and `process` stores and daravel_redis's
/// support it; the `file` and `database` stores do not, as in Laravel.
abstract interface class TaggableCacheStore implements CacheStore {
  /// This store under [names]; [prefix] is the cache prefix the
  /// repository would have put before each key, which a tagged store lays
  /// out as Laravel does (`<prefix><sha1>:<key>`).
  TaggedCacheStore tags(List<String> names, {String prefix = ''});
}

/// A store seen through tags ([TaggableCacheStore.tags]): keys are
/// namespaced by the tags, in their order, and [flush] forgets only what
/// they tagged.
abstract interface class TaggedCacheStore implements CacheStore {
  /// The tags, in the order given.
  List<String> get names;

  /// The key [key] is stored under (Laravel's `taggedItemKey`, after the
  /// cache prefix).
  Future<String> itemKey(String key);

  /// Drops expired entries from the tags' bookkeeping (Redis's tag sets;
  /// nothing elsewhere).
  Future<void> flushStale();
}

/// Laravel's `TagSet` and `TaggedCache` over any store: each tag has a
/// random id (`tag:<name>:key`), keys live under the SHA-1 of the ids, and a
/// flush gives the tags new ids, so what they tagged is no longer reached
/// (and expires, or leaves the memory store's LRU).
final class TagSetCacheStore implements TaggedCacheStore {
  TagSetCacheStore(this.store, this.names, {this.prefix = ''});

  final CacheStore store;
  @override
  final List<String> names;
  final String prefix;

  static final Random _random = Random.secure();

  @override
  StateScope get scope => store.scope;

  String _tagKey(String name) => '${prefix}tag:$name:key';

  Future<String> _tagId(String name) async {
    final id = await store.get(_tagKey(name));
    return id is String && id.isNotEmpty ? id : _resetTag(name);
  }

  Future<String> _resetTag(String name) async {
    final id = [
      for (var i = 0; i < 12; i++)
        _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    await store.forever(_tagKey(name), id);
    return id;
  }

  @override
  Future<String> itemKey(String key) async {
    final ids = [for (final name in names) await _tagId(name)];
    return '$prefix${sha1.convert(utf8.encode(ids.join('|')))}:$key';
  }

  @override
  Future<Object?> get(String key) async => store.get(await itemKey(key));

  @override
  Future<Map<String, Object?>> many(List<String> keys) async {
    final items = [for (final key in keys) await itemKey(key)];
    final found = await store.many(items);
    return {for (var i = 0; i < keys.length; i++) keys[i]: found[items[i]]};
  }

  @override
  Future<void> put(String key, Object? value, {Duration? ttl}) async =>
      store.put(await itemKey(key), value, ttl: ttl);

  @override
  Future<void> putMany(Map<String, Object?> values, {Duration? ttl}) async {
    for (final MapEntry(:key, :value) in values.entries) {
      await put(key, value, ttl: ttl);
    }
  }

  @override
  Future<bool> add(String key, Object? value, {Duration? ttl}) async =>
      store.add(await itemKey(key), value, ttl: ttl);

  @override
  Future<int> increment(String key, [int by = 1]) async =>
      store.increment(await itemKey(key), by);

  @override
  Future<int> decrement(String key, [int by = 1]) async =>
      store.decrement(await itemKey(key), by);

  @override
  Future<void> forever(String key, Object? value) async =>
      store.forever(await itemKey(key), value);

  @override
  Future<bool> forget(String key) async => store.forget(await itemKey(key));

  /// New ids for the tags (Laravel's `TagSet::reset`).
  @override
  Future<void> flush() async {
    for (final name in names) {
      await _resetTag(name);
    }
  }

  @override
  Future<void> flushStale() async {}

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
