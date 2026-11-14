import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/raw_ws_client.dart';

/// permessage-deflate is off unless a route asks for it: a client that
/// offers it on a default route gets an uncompressed connection.
void main() {
  late Application app;
  late ServerEngine engine;

  Future<void> echo(WebSocket socket, Request _) {
    final done = Completer<void>();
    socket.listen(socket.add, onDone: done.complete);
    return done.future;
  }

  setUp(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) => router
            ..ws('/default', echo)
            ..ws('/compressed', echo, compress: true)
            ..get('/response', (Request request) {
              if (!isWebSocketUpgrade(request)) {
                return Response.text('no');
              }
              return Response.webSocket(echo);
            }),
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

  for (final path in ['/default', '/response']) {
    test('$path: a client offering permessage-deflate gets none', () async {
      final headers = await RawWsClient.handshake(
        engine.port!,
        path,
        deflate: true,
      );
      expect(headers.containsKey('sec-websocket-extensions'), isFalse);
    });
  }

  test('compress: true agrees to it', () async {
    final headers = await RawWsClient.handshake(
      engine.port!,
      '/compressed',
      deflate: true,
    );
    expect(headers['sec-websocket-extensions'], contains('permessage-deflate'));
  });

  test('a compressed frame on a default route is refused with 1002', () async {
    final client = await RawWsClient.connect(engine.port!, '/default');
    client.send(0x1, Uint8List.fromList([0xF2, 0x48, 0xCD, 0xC9]), rsv1: true);
    expect(await client.closeFrame(), 1002);
    client.socket.destroy();
  }, skip: 'needs the frame checks of the unread-handlers change (#400)');
}
