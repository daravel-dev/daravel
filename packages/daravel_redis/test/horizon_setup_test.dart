import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

Application createApp() => throw UnimplementedError('not started here');

/// `HORIZON_STORE=redis` resolves the redis store whichever of
/// `withHorizon()` and `withRedis()` comes first; nothing connects until
/// the store is used, so no server is needed here.
void main() {
  Future<Application> boot(
    ApplicationBuilder Function(ApplicationBuilder) wire, {
    String store = 'redis',
  }) async {
    final app = wire(
      Application.configure(basePath: Directory.systemTemp.path).withEnv({
        'APP_ENV': 'testing',
        'DB_DATABASE': ':memory:',
        'HORIZON_STORE': store,
        'HORIZON_STORE_MAX_PER_STATUS': '500',
        'REDIS_PREFIX': 'shop-database-',
      }),
    ).create();
    await app.boot();
    addTearDown(app.shutdown);
    return app;
  }

  for (final (label, wire) in [
    (
      'withHorizon() first',
      (ApplicationBuilder b) => b.withHorizon(createApp: createApp).withRedis(),
    ),
    (
      'withRedis() first',
      (ApplicationBuilder b) => b.withRedis().withHorizon(createApp: createApp),
    ),
  ]) {
    test('HORIZON_STORE=redis, $label', () async {
      final app = await boot(wire);
      final store = app.container.make<HorizonStore>();
      expect(store, isA<RedisHorizonStore>());
      store as RedisHorizonStore;
      expect(store.prefix, 'shop-database-');
      expect(store.maxPerStatus, 500);
    });
  }

  test('HORIZON_STORE=redis without withRedis() stops the boot', () async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'HORIZON_STORE': 'redis',
        })
        .withHorizon(createApp: createApp)
        .create();
    await expectLater(app.boot(), throwsA(isA<ConfigException>()));
  });

  test('HORIZON_STORE_MAX_PER_STATUS below 1 is a config error', () async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'HORIZON_STORE_MAX_PER_STATUS': '0',
        })
        .withHorizon(createApp: createApp)
        .create();
    await expectLater(app.boot(), throwsA(isA<ConfigException>()));
  });
}
