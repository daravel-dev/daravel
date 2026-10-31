import 'dart:async';

import '../cache/cache.dart';
import '../foundation/container.dart';

/// Cache access (`Cache::get`, `Cache::remember`, `Cache::lock`).
abstract final class Cache {
  static CacheManager get manager => Container.current.make<CacheManager>();

  /// The default store, or [name] (`Cache::store('file')`).
  static CacheRepository store([String? name]) => manager.store(name);

  /// The default store with its entries tagged [names] (Laravel's
  /// `Cache::tags`).
  static CacheRepository tags(List<String> names) => store().tags(names);

  static Future<T?> get<T>(String key, [T? fallback]) =>
      store().get<T>(key, fallback);

  static Future<bool> has(String key) => store().has(key);

  static Future<bool> missing(String key) => store().missing(key);

  static Future<Map<String, Object?>> many(List<String> keys) =>
      store().many(keys);

  static Future<void> put(String key, Object? value, {Duration? ttl}) =>
      store().put(key, value, ttl: ttl);

  static Future<void> putMany(Map<String, Object?> values, {Duration? ttl}) =>
      store().putMany(values, ttl: ttl);

  static Future<bool> add(String key, Object? value, {Duration? ttl}) =>
      store().add(key, value, ttl: ttl);

  static Future<int> increment(String key, [int by = 1]) =>
      store().increment(key, by);

  static Future<int> decrement(String key, [int by = 1]) =>
      store().decrement(key, by);

  static Future<void> forever(String key, Object? value) =>
      store().forever(key, value);

  static Future<bool> touch(String key, Duration ttl) =>
      store().touch(key, ttl);

  static Future<bool> forget(String key) => store().forget(key);

  static Future<T?> pull<T>(String key, [T? fallback]) =>
      store().pull<T>(key, fallback);

  static Future<void> flush() => store().flush();

  static Future<T> remember<T>(
    String key,
    Duration? ttl,
    FutureOr<T> Function() compute,
  ) => store().remember<T>(key, ttl, compute);

  static Future<T> rememberForever<T>(
    String key,
    FutureOr<T> Function() compute,
  ) => store().rememberForever<T>(key, compute);

  static Future<T> flexible<T>(
    String key,
    (Duration fresh, Duration stale) window,
    FutureOr<T> Function() compute,
  ) => store().flexible<T>(key, window, compute);

  static Lock lock(
    String name, {
    Duration ttl = const Duration(seconds: 10),
    String? owner,
  }) => store().lock(name, ttl: ttl, owner: owner);
}
