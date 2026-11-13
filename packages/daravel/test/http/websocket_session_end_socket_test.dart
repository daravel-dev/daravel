import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/raw_ws_client.dart';

/// A WebSocket session ends when its client closes or goes away, also when
/// its handler never wrote nor closed, and when its handler returned
/// without listening: before, such a session kept its scope and its place
/// in the server's list until the server stopped. Nothing of it is logged
/// as an error.
void main() {
  late Application app;
  late ServerEngine engine;
  late MemoryHandler log;

  /// Sockets a handler left open, for the test to close from outside.
  final held = <WebSocket>[];

  setUp(() async {
    held.clear();
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) => router
            ..ws('/listen', (socket, _) {
              // Reads, never writes nor closes.
              final done = Completer<void>();
              socket.listen((_) {}, onDone: done.complete);
              return done.future;
            }, compress: false)
            ..ws('/greet', (socket, _) {
              // Writes once and returns, never listening.
              socket.add('hello');
            }, compress: false)
            ..ws('/greet-later', (socket, _) {
              // Returns at once; writes once more a little later.
              Timer(
                const Duration(milliseconds: 200),
                () => socket.add('later'),
              );
            }, compress: false)
            ..ws('/bye', (socket, _) async {
              // Writes, closes and returns, never listening.
              socket.add('bye');
              await socket.close(1000);
            }, compress: false)
            ..ws('/bye-no-code', (socket, _) async {
              socket.add('bye');
              await socket.close();
            }, compress: false)
            ..ws(
              '/close-only',
              (socket, _) => socket.close(1000),
              compress: false,
            )
            ..ws('/held', (socket, _) {
              // Returns; the application closes it later from outside.
              held.add(socket);
              socket.add('hello');
            }, compress: false),
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

  void expectNoErrors() => expect(
    log.records.where((r) => r.level.index >= LogLevel.error.index),
    isEmpty,
    reason: 'nothing logged as an error',
  );

  Future<void> expectSessionEnded() async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (engine.openWebSockets > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(engine.openWebSockets, 0, reason: 'the session ended');
    expectNoErrors();
  }

  Future<void> openAndEnd(
    String path,
    Future<void> Function(RawWsClient client) end,
  ) async {
    final client = await RawWsClient.connect(engine.port!, path);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(engine.openWebSockets, 1);
    await end(client);
    await expectSessionEnded();
  }

  for (final (path, handler) in [
    ('/listen', 'a handler that listens'),
    ('/greet', 'a handler that returned without listening'),
  ]) {
    group(handler, () {
      test('the client closes with a close frame: the session ends', () async {
        await openAndEnd(path, (client) => client.close());
      });

      test('the client drops the TCP connection: the session ends', () async {
        await openAndEnd(path, (client) async => client.socket.destroy());
      });
    });
  }

  group('a handler that closes the socket itself', () {
    for (final (path, code) in [('/bye', 1000), ('/bye-no-code', null)]) {
      test('writes, closes ($path) and returns: the client gets both, the '
          'session ends', () async {
        final client = await RawWsClient.connect(engine.port!, path);
        expect(String.fromCharCodes((await client.next()).payload), 'bye');
        final close = await client.next();
        expect(close.opcode, 0x8);
        expect(close.closeCode, code);
        await client.close();
        await expectSessionEnded();
      });
    }

    test('closes without writing and returns', () async {
      final client = await RawWsClient.connect(engine.port!, '/close-only');
      expect(await client.closeFrame(), 1000);
      await client.close();
      await expectSessionEnded();
    });

    test('returns, and the application closes it later from outside', () async {
      final client = await RawWsClient.connect(engine.port!, '/held');
      expect(String.fromCharCodes((await client.next()).payload), 'hello');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await held.single.close(4001, 'later');
      expect(await client.closeFrame(), 4001);
      await client.close();
      await expectSessionEnded();
    });
  });

  group('a handler that returned without listening, then a client that '
      'breaks the protocol', () {
    Future<void> expectEndedQuietly() async {
      await expectSessionEnded();
      // The server goes on serving.
      final next = await RawWsClient.connect(engine.port!, '/greet');
      expect(String.fromCharCodes((await next.next()).payload), 'hello');
      await next.close();
    }

    test('an unmasked frame', () async {
      final client = await RawWsClient.connect(engine.port!, '/greet');
      await client.next(); // hello
      client.socket.add(const [0x81, 0x02, 0x68, 0x69]);
      await expectEndedQuietly();
    });

    test('a text message that is not UTF-8', () async {
      final client = await RawWsClient.connect(engine.port!, '/greet');
      await client.next(); // hello
      client.send(0x1, const [0xFF, 0xFE, 0xFD]);
      await expectEndedQuietly();
    });

    test('a reset in the middle of a frame', () async {
      final client = await RawWsClient.connect(engine.port!, '/greet-later');
      // Unread data when the socket closes makes the OS reset it.
      client.pauseReading();
      client.socket
        ..add(RawWsClient.header(0x2, 1000))
        ..add(List<int>.filled(10, 0));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      client.socket.destroy();
      await expectEndedQuietly();
    });
  });
}
