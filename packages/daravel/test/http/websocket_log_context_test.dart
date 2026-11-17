import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/raw_ws_client.dart';

/// What the server logs about a WebSocket names its path, not only the
/// request id.
void main() {
  late Application app;
  late ServerEngine engine;
  late MemoryHandler log;

  setUp(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) => router
            ..ws('/boom', (socket, _) => throw StateError('boom'))
            ..ws('/small', (socket, _) {
              socket.listen((_) {});
            }, maxPayloadBytes: 1024)
            ..ws('/slow', (socket, _) async {
              while (socket.readyState == WebSocket.open) {
                socket.add(Uint8List(64 << 10));
                await Future<void>.delayed(Duration.zero);
              }
            }, maxBufferedBytes: 1 << 20),
        )
        .create();
    await app.boot();
    engine = ServerEngine(
      app,
      const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
      kernel: app.kernel,
      logger: Logger(handlers: [log = MemoryHandler()]),
    );
    await engine.start();
  });

  tearDown(() async {
    await engine.stop();
    await app.shutdown();
  });

  Future<LogRecord> logged(Pattern message) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      for (final record in log.records) {
        if (record.message.contains(message)) {
          return record;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    fail('nothing logged matching $message');
  }

  test('a handler that throws', () async {
    final client = await RawWsClient.connect(engine.port!, '/boom');
    final record = await logged('WebSocket handler failed');
    expect(record.context['path'], '/boom');
    client.socket.destroy();
  });

  test('a violation', () async {
    final client = await RawWsClient.connect(engine.port!, '/small');
    client.send(0x2, Uint8List(4096));
    final record = await logged('WebSocket closed (1009)');
    expect(record.context['path'], '/small');
    client.socket.destroy();
  });

  test('a slow client', () async {
    final client = await RawWsClient.connect(engine.port!, '/slow');
    client.pauseReading();
    final record = await logged('read too slowly');
    expect(record.context['path'], '/slow');
    client.socket.destroy();
  });
}
