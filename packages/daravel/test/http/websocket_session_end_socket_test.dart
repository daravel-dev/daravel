import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/raw_ws_client.dart';

/// A WebSocket session ends when its client closes or goes away, also when
/// its handler never wrote nor closed: before, such a session kept its
/// scope and its place in the server's list until the server stopped.
void main() {
  late Application app;
  late ServerEngine engine;

  setUp(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) => router.ws('/listen', (socket, _) {
            // Reads, never writes nor closes.
            final done = Completer<void>();
            socket.listen((_) {}, onDone: done.complete);
            return done.future;
          }, compress: false),
        )
        .create();
    await app.boot();
    engine = ServerEngine(
      app,
      const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
      kernel: app.kernel,
      logger: Logger(handlers: [MemoryHandler()]),
    );
    await engine.start();
  });

  tearDown(() async {
    await engine.stop();
    await app.shutdown();
  });

  Future<int> openAfter(Future<void> Function(RawWsClient client) end) async {
    final client = await RawWsClient.connect(engine.port!, '/listen');
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(engine.openWebSockets, 1);
    await end(client);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (engine.openWebSockets > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return engine.openWebSockets;
  }

  test('the client closes with a close frame: the session ends', () async {
    expect(await openAfter((client) => client.close()), 0);
  });

  test('the client drops the TCP connection: the session ends', () async {
    expect(await openAfter((client) async => client.socket.destroy()), 0);
  });
}
