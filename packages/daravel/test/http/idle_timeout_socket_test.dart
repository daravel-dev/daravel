import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A keep-alive connection a client opens and leaves idle is closed by the
/// server after `HTTP_IDLE_TIMEOUT`, so idle sockets are bounded.
void main() {
  test(
    'an idle keep-alive connection is closed after HTTP_IDLE_TIMEOUT',
    () async {
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withRouting(
            apiPrefix: '',
            api: (router) => router.get('/ping', (_) => 'pong'),
          )
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      final options = ServeOptions.fromEnv(
        Env.fromMap({'HTTP_IDLE_TIMEOUT': '400ms'}),
        host: '127.0.0.1',
        port: 0,
      );
      expect(options.idleTimeout, const Duration(milliseconds: 400));
      expect(const ServeOptions().idleTimeout, const Duration(seconds: 60));
      final engine = ServerEngine(
        app,
        ServeOptions(
          host: '127.0.0.1',
          port: 0,
          handleSignals: false,
          idleTimeout: options.idleTimeout,
        ),
        kernel: app.kernel,
        logger: Logger(minimumLevel: .critical),
      );
      await engine.start();
      addTearDown(engine.stop);

      // One request on a keep-alive connection, then silence.
      final socket = await Socket.connect('127.0.0.1', engine.port!);
      socket.write('GET /ping HTTP/1.1\r\nHost: localhost\r\n\r\n');
      await socket.flush();
      final watch = Stopwatch()..start();
      final reply = await utf8.decoder
          .bind(socket)
          .join()
          .timeout(const Duration(seconds: 5));
      socket.destroy();
      expect(reply, startsWith('HTTP/1.1 200'));
      expect(reply, endsWith('pong'));
      // The join only completes once the server closed the idle connection.
      expect(watch.elapsed, greaterThan(const Duration(milliseconds: 300)));
      expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
    },
  );
}
