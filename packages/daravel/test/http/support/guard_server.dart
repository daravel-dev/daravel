import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

  late final ServerEngine engine;
  // Sends 100 messages of 1 MiB, one every 10 ms, while the socket is
  // open: the server goes on writing after the client is gone.
  var firehoseEnded = 0;
  Future<void> firehose(WebSocket socket, Request _) async {
    final message = Uint8List(1 << 20);
    socket.listen((_) {});
    for (var i = 0; i < 100 && socket.readyState == WebSocket.open; i++) {
      socket.add(message);
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    firehoseEnded++;
    await socket.close();
  }

  final app = Application.configure(basePath: Directory.systemTemp.path)
      .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
      .withLogLevel(LogLevel.critical)
      .withRouting(
        web: (router) {
          router
            ..get('/rss', (_) => '${ProcessInfo.currentRss}')
            // The highest resident memory so far: memory handed back to the
            // system does not lower it.
            ..get('/maxrss', (_) => '${ProcessInfo.maxRss}')
            ..get('/open', (_) => '${engine.openWebSockets}')
            ..get('/firehose-ended', (_) => '$firehoseEnded')
            ..ws(
              '/firehose',
              firehose,
              compress: false,
              maxBufferedBytes: 8 << 20,
            )
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
  engine = ServerEngine(
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
