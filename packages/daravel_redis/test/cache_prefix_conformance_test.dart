@Tags(['conformance'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

/// The Redis key of a cache entry, as Laravel's `RedisStore` builds it
/// (`$this->prefix.$key`, after the connection's `prefix` option), per
/// `COMPAT_LARAVEL_VERSION`. `setPrefix` in laravel/framework:
///
/// - v9.52.16 and v10.48.29: `$this->prefix = ! empty($prefix) ? $prefix.':'
///   : '';`
/// - v11.0.0, v11.45.1 and 12.x: `$this->prefix = $prefix;`
///
/// No server is needed: nothing connects until a command is sent.
void main() {
  final client = RedisClient(
    RedisConnectionConfig.fromUrl('redis://127.0.0.1:1'),
  );
  tearDownAll(client.close);

  String keyFor(int? compat, String cachePrefix, String key) {
    final store = RedisStore(
      client,
      prefix: 'app_database_',
      laravelCompat: compat,
    );
    final repository = CacheRepository(store, prefix: cachePrefix);
    return store.keyOf('${repository.prefix}$key');
  }

  test('up to Laravel 10 the cache prefix is followed by a colon', () {
    for (final compat in [9, 10]) {
      expect(
        keyFor(compat, 'app_cache_', 'libsodium:session-key:abc'),
        'app_database_app_cache_:libsodium:session-key:abc',
        reason: 'Laravel $compat',
      );
    }
  });

  test('from Laravel 11 it is kept as given', () {
    for (final compat in [11, 12]) {
      expect(
        keyFor(compat, 'app-cache-', 'libsodium:session-key:abc'),
        'app_database_app-cache-libsodium:session-key:abc',
        reason: 'Laravel $compat',
      );
    }
  });

  test('an empty prefix gets no colon, in any version', () {
    for (final compat in [9, 10, 11, 12]) {
      expect(keyFor(compat, '', 'k'), 'app_database_k', reason: '$compat');
    }
  });

  test("outside an application, the default (Laravel 12) layout", () {
    expect(keyFor(null, 'app_cache_', 'k'), 'app_database_app_cache_k');
  });

  test("the application's COMPAT_LARAVEL_VERSION reaches the store", () async {
    Future<String> prefixUnder(String version) async {
      final base = Directory.systemTemp.createTempSync('daravel_redis_prefix');
      addTearDown(() => base.deleteSync(recursive: true));
      final app = Application.configure(basePath: base.path)
          .withRedis()
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'CACHE_STORE': 'redis',
            'CACHE_PREFIX': 'app_cache_',
            'REDIS_URL': 'redis://127.0.0.1:1',
            'COMPAT_LARAVEL_VERSION': version,
          })
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      return app.run(() async => Cache.store().prefix);
    }

    expect(await prefixUnder('10'), 'app_cache_:');
    expect(await prefixUnder('12'), 'app_cache_');
  });
}
