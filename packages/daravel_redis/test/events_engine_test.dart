@Tags(['integration'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

/// Server-sent events through `ServerEngine`: a connection whose
/// `Last-Event-ID` is no stream id receives live events, and nothing is
/// logged as an error (before, each event logged an uncaught error per
/// such connection, which never got one). With `DARAVEL_TEST_REDIS`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_REDIS'];
  if (url == null || url.isEmpty) {
    test(
      'events through the engine (skipped: DARAVEL_TEST_REDIS not set)',
      () {},
      skip: true,
    );
    return;
  }

  test('a malformed Last-Event-ID gets live events, no error logged', () async {
    final prefix = 'test_${Random().nextInt(1 << 32)}_';
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withRedis()
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'REDIS_URL': url,
          'REDIS_PREFIX': prefix,
        })
        .withLogLevel(LogLevel.critical)
        .withRouting(
          apiPrefix: '',
          api: (router) => router.get(
            '/sse',
            (request) => Response.sse(Redis.events('orders').since(request)),
          ),
        )
        .create();
    await app.boot();
    final logs = MemoryHandler();
    final engine = ServerEngine(
      app,
      const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
      kernel: app.kernel,
      logger: Logger(minimumLevel: LogLevel.warning, handlers: [logs]),
    );
    await engine.start();
    addTearDown(() async {
      await engine.stop();
      await app.run(
        () async => Redis.connection().del(['${prefix}sse:orders']),
      );
      await app.shutdown();
    });

    final socket = await Socket.connect('127.0.0.1', engine.port!);
    addTearDown(socket.destroy);
    final received = StringBuffer();
    final gotHeaders = Completer<void>();
    final gotEvent = Completer<void>();
    socket.listen((bytes) {
      received.write(utf8.decode(bytes, allowMalformed: true));
      final text = '$received';
      if (!gotHeaders.isCompleted && text.contains('\r\n\r\n')) {
        gotHeaders.complete();
      }
      if (!gotEvent.isCompleted && text.contains('data: live')) {
        gotEvent.complete();
      }
    });
    socket.write(
      'GET /sse HTTP/1.1\r\nHost: localhost\r\n'
      'Accept: text/event-stream\r\nLast-Event-ID: abc\r\n\r\n',
    );
    await gotHeaders.future.timeout(const Duration(seconds: 10));
    expect('$received', startsWith('HTTP/1.1 200'));
    // Live events reach it, more than one.
    for (var i = 0; i < 3; i++) {
      await app.run(() => Redis.events('orders').publish('live'));
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await gotEvent.future.timeout(const Duration(seconds: 10));
    expect([
      for (final r in logs.records)
        if (r.level.index >= LogLevel.error.index) r.message,
    ], isEmpty);
  });
}
