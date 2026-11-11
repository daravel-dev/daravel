import 'dart:async';

import '../cache/cache.dart';
import '../foundation/container.dart';

/// Cache access (`Cache::get`, `Cache::remember`, `Cache::lock`).
abstract final class Cache {
  /// The cache manager of the current container.
  static CacheManager get manager => Container.current.make<CacheManager>();

  /// The default store, or [name] (`Cache::store('file')`).
  static CacheRepository store([String? name]) => manager.store(name);

  /// The default store with its entries tagged [names] (Laravel's
  /// `Cache::tags`).
  static CacheRepository tags(List<String> names) => store().tags(names);

  /// The value of [key], or [fallback] when missing.
  static Future<T?> get<T>(String key, [T? fallback]) =>
      store().get<T>(key, fallback);

  /// Whether [key] holds a value.
  static Future<bool> has(String key) => store().has(key);

  /// Whether [key] holds nothing.
  static Future<bool> missing(String key) => store().missing(key);

  /// The values of [keys], null for the missing ones.
  static Future<Map<String, Object?>> many(List<String> keys) =>
      store().many(keys);

  /// Stores [value] under [key], for [ttl] or forever.
  static Future<void> put(String key, Object? value, {Duration? ttl}) =>
      store().put(key, value, ttl: ttl);

  /// Stores every entry of [values].
  static Future<void> putMany(Map<String, Object?> values, {Duration? ttl}) =>
      store().putMany(values, ttl: ttl);

  /// Stores [value] only when [key] is missing; returns whether it did.
  static Future<bool> add(String key, Object? value, {Duration? ttl}) =>
      store().add(key, value, ttl: ttl);

  /// Adds [by] to the integer under [key] and returns the new value.
  static Future<int> increment(String key, [int by = 1]) =>
      store().increment(key, by);

  /// Subtracts [by] from the integer under [key] and returns the new value.
  static Future<int> decrement(String key, [int by = 1]) =>
      store().decrement(key, by);

  /// Stores [value] under [key] with no expiry.
  static Future<void> forever(String key, Object? value) =>
      store().forever(key, value);

  /// Gives [key] a new [ttl]; returns whether it existed.
  static Future<bool> touch(String key, Duration ttl) =>
      store().touch(key, ttl);

  /// Removes [key]; returns whether it existed.
  static Future<bool> forget(String key) => store().forget(key);

  /// The value of [key], removed from the cache.
  static Future<T?> pull<T>(String key, [T? fallback]) =>
      store().pull<T>(key, fallback);

  /// Removes every value of the default store; its locks stay.
  static Future<void> flush() => store().flush();

  /// Releases every lock of the default store ([flush] keeps them).
  static Future<void> flushLocks() => store().flushLocks();

  /// Deletes the expired entries and locks of the default store; returns
  /// how many (see [CacheRepository.pruneExpired]).
  static Future<int> pruneExpired() => store().pruneExpired();

  /// The value of [key], or the callback's result stored for the given
  /// ttl: `Cache.remember('stats', 10.minutes, () => compute())`.
  static Future<T> remember<T>(
    String key,
    Duration? ttl,
    FutureOr<T> Function() compute,
  ) => store().remember<T>(key, ttl, compute);

  /// The value of [key], or the callback's result stored forever.
  static Future<T> rememberForever<T>(
    String key,
    FutureOr<T> Function() compute,
  ) => store().rememberForever<T>(key, compute);

  /// Stale-while-revalidate: fresh for the first duration, then served
  /// stale while it refreshes in the background, until the second.
  static Future<T> flexible<T>(
    String key,
    (Duration fresh, Duration stale) window,
    FutureOr<T> Function() compute,
  ) => store().flexible<T>(key, window, compute);

  /// An atomic lock named by the key, held for the given duration:
  /// `await Cache.lock('report', 10.seconds).get(() => ...)`.
  static Lock lock(
    String name, {
    Duration ttl = const Duration(seconds: 10),
    String? owner,
  }) => store().lock(name, ttl: ttl, owner: owner);
}
