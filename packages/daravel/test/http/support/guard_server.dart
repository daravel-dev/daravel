import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';

/// A server for websocket_guard_memory_test.dart, in a process of its own
/// so its memory (`GET /rss`) is not mixed with the other test files that
/// run at the same time. Prints `PORT <port>` once listening, and its
/// warnings (a guard closing a connection) as `LOG <message>`.
Future<void> main() async {
  Future<void> echo(WebSocket socket, Request _) {
    final done = Completer<void>();
    socket.listen(socket.add, onDone: done.complete);
    return done.future;
  }

  final app = Application.configure(basePath: Directory.systemTemp.path)
      .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
      .withLogLevel(LogLevel.critical)
      .withRouting(
        web: (router) {
          router
            ..get('/rss', (_) => '${ProcessInfo.currentRss}')
            ..ws('/echo', echo, compress: false, maxPayloadBytes: 65536)
            ..ws(
              '/silent',
              (socket, _) => socket.done,
              compress: false,
              maxPayloadBytes: 65536,
            )
            ..ws(
              '/flood',
              echo,
              compress: false,
              maxBufferedBytes: 65536,
              controlFrameBurst: 1 << 30,
              controlFramesPerSecond: 1 << 30,
            );
        },
      )
      .create();
  await app.boot();
  final engine = ServerEngine(
    app,
    const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
    kernel: app.kernel,
    logger: Logger(minimumLevel: LogLevel.warning, handlers: [_Stdout()]),
  );
  await engine.start();
  stdout.writeln('PORT ${engine.port}');
  // Runs until the test kills it.
  await Completer<void>().future;
}

final class _Stdout implements LogHandler {
  @override
  void handle(LogRecord record) => stdout.writeln('LOG ${record.message}');

  @override
  Future<void> close() async {}
}
