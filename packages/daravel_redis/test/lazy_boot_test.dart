import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

Application redisApp(int port) =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'REDIS_HOST': '127.0.0.1',
          'REDIS_PORT': '$port',
          'CACHE_STORE': 'redis',
          'CACHE_LIMITER': 'redis',
          'QUEUE_CONNECTION': 'redis',
          'QUEUE_UNIQUE_LOCK_STORE': 'redis',
        })
        .withLogLevel(LogLevel.critical)
        .withRedis()
        .create();

/// `withRedis()` connects on first use, not at boot: an application whose
/// Redis is down or not yet reachable (a command, a deploy step, tests)
/// boots, and its first Redis command is the first to fail.
void main() {
  test('boot with every store on Redis opens no connection; the first '
      'use does', () async {
    // A listener that never answers: it counts who connects.
    final listener = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final accepted = <Socket>[];
    listener.listen(accepted.add);
    addTearDown(() async {
      for (final socket in accepted) {
        socket.destroy();
      }
      await listener.close();
    });

    final app = redisApp(listener.port);
    await app.boot();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(accepted, isEmpty, reason: 'boot connected to Redis');

    // The counter works: the first cache read connects.
    unawaited(
      app
          .run(() => Cache.get<Object?>('k'))
          .timeout(const Duration(seconds: 2))
          .then<void>((_) {}, onError: (Object _) {}),
    );
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (accepted.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(accepted, isNotEmpty, reason: 'the first use connects');
    for (final socket in accepted) {
      socket.destroy();
    }
    await app.shutdown();
  });

  test('boot succeeds with nothing listening at the Redis address', () async {
    final free = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = free.port;
    await free.close();
    final app = redisApp(port);
    await app.boot().timeout(const Duration(seconds: 10));
    expect(app.container.make<CacheManager>(), isNotNull);
    await app.shutdown();
  });
}
