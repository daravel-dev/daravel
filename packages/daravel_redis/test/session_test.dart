import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:daravel_session/daravel_session.dart';
import 'package:test/test.dart';

/// `SESSION_DRIVER=redis` as Laravel 12 lays it out
/// (`SessionManager::createRedisDriver`, `CacheBasedSessionHandler`,
/// `RedisStore::put`): `SETEX` of the key `REDIS_PREFIX` + `CACHE_PREFIX` +
/// id, for the lifetime in seconds, holding `serialize($payload)`, on the
/// `SESSION_CONNECTION` connection (`default` when unset).
///
/// The layout needs no server; the round trip runs against a real Redis or
/// Valkey when `DARAVEL_TEST_REDIS` is set.
void main() {
  Future<Application> boot(
    Map<String, String> env, {
    bool sessionFirst = false,
  }) async {
    final base = Directory.systemTemp.createTempSync('daravel_redis_session');
    addTearDown(() => base.deleteSync(recursive: true));
    final builder = Application.configure(basePath: base.path);
    final app =
        (sessionFirst
                ? builder.withSession().withRedis()
                : builder.withRedis().withSession())
            .withEnv({
              'APP_ENV': 'testing',
              'APP_NAME': 'Shop',
              'DB_DATABASE': ':memory:',
              'SESSION_DRIVER': 'redis',
              'REDIS_URL': 'redis://127.0.0.1:1',
              'REDIS_PREFIX': 'shop-database-',
              'CACHE_PREFIX': 'shop-cache-',
              ...env,
            })
            .withLogLevel(LogLevel.warning)
            .create();
    await app.boot();
    addTearDown(app.shutdown);
    return app;
  }

  Future<CacheSessionHandler> handlerOf(Application app) => app.run(
    () async => App.make<SessionManager>().handler as CacheSessionHandler,
  );

  group('layout', () {
    test('<REDIS_PREFIX><CACHE_PREFIX><id> on the default connection, '
        'whichever of withSession() and withRedis() comes first', () async {
      for (final sessionFirst in [false, true]) {
        final app = await boot(const {}, sessionFirst: sessionFirst);
        final handler = await handlerOf(app);
        final store = handler.cache.store as RedisStore;
        expect(
          store.keyOf('${handler.cache.prefix}abc'),
          'shop-database-shop-cache-abc',
        );
        await app.run(() async {
          expect(store.client, same(Redis.connection('default')));
        });
        expect(handler.lifetime, const Duration(minutes: 120));
      }
    });

    test('SESSION_CONNECTION picks the connection; Laravel 10 adds the '
        'colon after the cache prefix', () async {
      final app = await boot(const {
        'SESSION_CONNECTION': 'cache',
        'COMPAT_LARAVEL_VERSION': '10',
        'SESSION_LIFETIME': '30',
      });
      final handler = await handlerOf(app);
      final store = handler.cache.store as RedisStore;
      await app.run(() async {
        expect(store.client, same(Redis.connection('cache')));
      });
      expect(
        store.keyOf('${handler.cache.prefix}abc'),
        'shop-database-shop-cache-:abc',
      );
      expect(handler.lifetime, const Duration(minutes: 30));
    });

    test('the payload is written as serialize() whatever REDIS_SERIALIZER '
        'says', () async {
      final app = await boot(const {'REDIS_SERIALIZER': 'json'});
      final store = (await handlerOf(app)).cache.store as RedisStore;
      expect(
        store.encode('a:1:{s:4:"name";s:5:"Désa";}'),
        's:29:"a:1:{s:4:"name";s:5:"Désa";}";',
      );
    });

    test('a redis driver the application registers wins', () async {
      final app = await boot(const {});
      final handler = await app.run(() async {
        final sessions = App.make<SessionManager>()
          ..extend(
            'redis',
            (config) => ArraySessionHandler(lifetime: config.lifetime),
          );
        return sessions.handler;
      });
      expect(handler, isA<ArraySessionHandler>());
    });

    test('an unknown SESSION_CONNECTION stops the boot', () async {
      final base = Directory.systemTemp.createTempSync('daravel_redis_session');
      addTearDown(() => base.deleteSync(recursive: true));
      final app = Application.configure(basePath: base.path)
          .withRedis()
          .withSession()
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'SESSION_DRIVER': 'redis',
            'SESSION_CONNECTION': 'sessions',
            'REDIS_URL': 'redis://127.0.0.1:1',
          })
          .withLogLevel(LogLevel.warning)
          .create();
      await expectLater(
        app.boot(),
        throwsA(
          predicate<Object>(
            (e) => '$e'.contains('SESSION_CONNECTION=sessions'),
          ),
        ),
      );
    });
  });

  final url = Platform.environment['DARAVEL_TEST_REDIS'];
  group('round trip', tags: ['integration'], () {
    if (url == null || url.isEmpty) {
      test(
        'Redis sessions (skipped: DARAVEL_TEST_REDIS not set)',
        () {},
        skip: true,
      );
      return;
    }
    late String prefix;
    late Application app;
    late RedisClient raw;

    setUp(() async {
      prefix = 'test_${Random().nextInt(1 << 32)}_';
      app = await boot({
        'REDIS_URL': url,
        'REDIS_PREFIX': prefix,
        'SESSION_LIFETIME': '30',
      });
      raw = RedisClient(RedisConnectionConfig.fromUrl(url));
      addTearDown(() async {
        final keys = await raw.scan(match: '$prefix*').toList();
        if (keys.isNotEmpty) {
          await raw.command(['DEL', ...keys]);
        }
        await raw.close();
      });
    });

    test(
      'Daravel writes what Laravel reads, with the lifetime as TTL',
      () async {
        final handler = await handlerOf(app);
        const id = 'DaravelWroteThisSessionIdOfFortyChars123';
        const payload = 'a:1:{s:4:"name";s:4:"Jane";}';
        await app.run(() => handler.write(id, payload));
        final key = '${prefix}shop-cache-$id';
        expect(await raw.get(key), 's:${payload.length}:"$payload";');
        final ttl = (await raw.command(['TTL', key]))! as int;
        expect(ttl, inInclusiveRange(30 * 60 - 5, 30 * 60));
        await app.run(() => handler.destroy(id));
        expect(await raw.get(key), isNull);
      },
    );

    test('Daravel reads what Laravel wrote', () async {
      final handler = await handlerOf(app);
      const id = 'LaravelWroteThisSessionIdOfFortyChars123';
      const payload = 'a:1:{s:4:"name";s:3:"Joe";}';
      await raw.command([
        'SETEX',
        '${prefix}shop-cache-$id',
        1800,
        's:${payload.length}:"$payload";',
      ]);
      expect(await app.run(() => handler.read(id)), payload);
    });
  });
}
