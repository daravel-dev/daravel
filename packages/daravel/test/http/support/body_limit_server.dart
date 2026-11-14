import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';

/// A server for chunked_body_limit_test.dart, in a process of its own so
/// its memory (`GET /rss`) is not mixed with the other test files that run
/// at the same time: `POST /echo` under `HTTP_MAX_BODY` of 64 KiB. Prints
/// `PORT <port>` once listening.
Future<void> main() async {
  const env = {
    'APP_ENV': 'testing',
    'DB_DATABASE': ':memory:',
    'HTTP_MAX_BODY': '65536',
  };
  final app = Application.configure(basePath: Directory.systemTemp.path)
      .withEnv(env)
      .withLogLevel(LogLevel.critical)
      .withRouting(
        apiPrefix: '',
        api: (router) {
          router
            ..get('/rss', (_) => '${ProcessInfo.currentRss}')
            ..post(
              '/echo',
              (request) async => {'length': (await request.bytes()).length},
            );
        },
      )
      .create();
  await app.boot();
  final engine = ServerEngine(
    app,
    ServeOptions.fromEnv(Env.fromMap(env), host: '127.0.0.1', port: 0),
    kernel: app.kernel,
    logger: Logger(minimumLevel: LogLevel.critical),
  );
  await engine.start();
  stdout.writeln('PORT ${engine.port}');
  // Runs until the test kills it.
  await Completer<void>().future;
}
