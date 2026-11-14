import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/raw_ws_client.dart';
import 'support/websocket_counts.dart';

/// A WebSocket session ends when its client closes or goes away, also when
/// its handler never wrote nor closed, and when its handler returned
/// without listening: before, such a session kept its scope and its place
/// in the server's list until the server stopped. Nothing of it is logged
/// as an error.
void main() {
  // First, so it runs last: after every tear-down of the tests.
  tearDown(expectWebSocketCountsReleased);

  late Application app;
  late ServerEngine engine;
  late MemoryHandler log;

  /// Sockets a handler left open, for the test to close from outside.
  final held = <WebSocket>[];

  /// What a handler that listens late received.
  final lateReceived = <Object?>[];

  /// What happened to a late listen: its `onDone` calls, and whether
  /// `listen` threw.
  var lateDone = 0;
  var lateThrew = false;

  setUp(() async {
    held.clear();
    lateReceived.clear();
    lateDone = 0;
    lateThrew = false;
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
            }, compress: false)
            ..ws('/late', (socket, request) {
              // Returns, then listens once its setup is done.
              socket.add('hi');
              final after = int.parse(request.uri.queryParameters['ms']!);
              final guarded = request.uri.queryParameters['try'] == '1';
              Timer(Duration(milliseconds: after), () {
                void listen() =>
                    socket.listen(lateReceived.add, onDone: () => lateDone++);
                if (!guarded) {
                  listen();
                  return;
                }
                try {
                  listen();
                } on Object {
                  lateThrew = true;
                }
              });
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

  /// The session ended within [within] (a handler that returned without
  /// listening is read by the server 5 s after it returned), with nothing
  /// logged as an error; how long it took.
  Future<int> expectSessionEnded({
    Duration within = const Duration(seconds: 10),
  }) async {
    final watch = Stopwatch()..start();
    final deadline = DateTime.now().add(within);
    while (engine.openWebSockets > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    printOnFailure('the session ended after ${watch.elapsedMilliseconds} ms');
    expect(engine.openWebSockets, 0, reason: 'the session ended');
    expectNoErrors();
    return watch.elapsedMilliseconds;
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
        await expectSessionEnded(within: const Duration(seconds: 1));
      });
    }

    test('closes without writing and returns', () async {
      final client = await RawWsClient.connect(engine.port!, '/close-only');
      expect(await client.closeFrame(), 1000);
      await client.close();
      await expectSessionEnded(within: const Duration(seconds: 1));
    });

    test('returns, and the application closes it later from outside', () async {
      final client = await RawWsClient.connect(engine.port!, '/held');
      expect(String.fromCharCodes((await client.next()).payload), 'hello');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await held.single.close(4001, 'later');
      expect(await client.closeFrame(), 4001);
      await client.close();
      await expectSessionEnded(within: const Duration(seconds: 1));
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

  group('a handler that returns and listens later', () {
    test(
      '40 ms later: it gets what the client sent before and after',
      () async {
        final client = await RawWsClient.connect(engine.port!, '/late?ms=40');
        expect(String.fromCharCodes((await client.next()).payload), 'hi');
        client.send(0x1, 'before'.codeUnits);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        client.send(0x1, 'after'.codeUnits);
        // Until both arrived (a loaded machine takes longer than 200 ms),
        // or a loss shows.
        final deadline = DateTime.now().add(const Duration(seconds: 3));
        while (lateReceived.length < 2 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(lateReceived, ['before', 'after']);
        await client.close();
        await expectSessionEnded(within: const Duration(seconds: 2));
      },
    );

    test('6 s later, after the server read for it: the listen does not '
        'throw, and it gets what the client sends from then on', () async {
      final client = await RawWsClient.connect(engine.port!, '/late?ms=6000');
      expect(String.fromCharCodes((await client.next()).payload), 'hi');
      client.send(0x1, 'dropped'.codeUnits);
      await Future<void>.delayed(const Duration(milliseconds: 6500));
      client.send(0x1, 'kept'.codeUnits);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(lateReceived, ['kept']);
      expectNoErrors();
      await client.close();
      await expectSessionEnded(within: const Duration(seconds: 2));
    });
  });

  group('a handler that returned and never listens', () {
    test('the client closes after 1 s: the session ends when the server '
        'reads for it, 5 s after the handler returned', () async {
      final watch = Stopwatch()..start();
      final client = await RawWsClient.connect(engine.port!, '/greet');
      await client.next(); // hello
      await Future<void>.delayed(const Duration(seconds: 1));
      await client.close();
      await expectSessionEnded();
      printOnFailure('ended ${watch.elapsedMilliseconds} ms after connect');
      expect(watch.elapsed, greaterThan(const Duration(milliseconds: 4500)));
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 6500)));
    });

    test('the client closes after 7 s: the session ends at once', () async {
      final client = await RawWsClient.connect(engine.port!, '/greet');
      await client.next(); // hello
      await Future<void>.delayed(const Duration(seconds: 7));
      await client.close();
      final ms = await expectSessionEnded(within: const Duration(seconds: 2));
      expect(ms, lessThan(1000));
    });
  });

  group('the client closes before a late listen (6 s after the handler '
      'returned)', () {
    for (final closeAt in const [1000, 5300]) {
      for (final guarded in const [false, true]) {
        test('closed at $closeAt ms, listen ${guarded ? 'inside' : 'without'} '
            'try: it does not throw, its onDone runs once, no data', () async {
          final client = await RawWsClient.connect(
            engine.port!,
            '/late?ms=6000${guarded ? '&try=1' : ''}',
          );
          await client.next(); // hi
          await Future<void>.delayed(Duration(milliseconds: closeAt));
          await client.close();
          // Past the listen at 6 s.
          await Future<void>.delayed(
            Duration(milliseconds: 6000 - closeAt + 500),
          );
          expect(lateThrew, isFalse);
          expect(lateDone, 1);
          expect(lateReceived, isEmpty);
          await expectSessionEnded(within: const Duration(seconds: 2));
        });
      }
    }
  });
}
