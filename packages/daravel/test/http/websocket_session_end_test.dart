import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
// The guard's counts, for tests; not part of the public library.
import 'package:daravel/src/http/websocket_stats.dart';
import 'package:test/test.dart';

import 'support/raw_ws_client.dart';
import 'support/websocket_counts.dart';

/// Every way a WebSocket session ends, whatever its handler was doing and
/// whatever the guard held then, releases what the session held: each
/// cell of (how it ends) x (what the handler does) x (what the guard
/// holds) ends the session, closes its socket and brings every count back
/// to zero. A search over the states, not a list of the paths we know.
void main() {
  tearDown(expectWebSocketCountsReleased);

  /// The lengths of the messages the handler of `/resume-after-close` got,
  /// and the close code it saw at its end.
  final got = <int>[];
  var ended = Completer<int?>();
  setUp(() {
    got.clear();
    ended = Completer<int?>();
  });

  /// The pending graces, once they are none or [within] passed.
  Future<int> gracesWithin(Duration within) async {
    final deadline = DateTime.now().add(within);
    var graces = WebSocketGuardStats.toJson()['graces']!;
    while (graces != 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      graces = WebSocketGuardStats.toJson()['graces']!;
    }
    return graces;
  }

  const handlers = ['never', 'late', 'reads', 'paused', 'resumes'];
  const holds = ['tail', 'held', 'assembling'];
  const ends = [
    'client-close',
    'client-gone',
    'server-close',
    'overflow',
    'stop',
    'violation',
    'cancel',
  ];

  /// What a handler of [kind] does with [socket]; [end] is how the server
  /// side ends the session, when it is the one that does.
  Future<void> handle(WebSocket socket, String kind, String end) async {
    StreamSubscription<dynamic>? reading;
    final done = socket.done;
    if (end == 'server-close') {
      Timer(const Duration(milliseconds: 300), () {
        unawaited(socket.close(4001).then<void>((_) {}, onError: (_) {}));
      });
    }
    if (end == 'overflow') {
      unawaited(() async {
        while (socket.readyState == WebSocket.open) {
          socket.add(Uint8List(64 << 10));
          await Future<void>.delayed(Duration.zero);
        }
      }());
    }
    switch (kind) {
      case 'never':
        break;
      case 'late':
        await Future<void>.delayed(const Duration(milliseconds: 150));
        reading = socket.listen((_) {});
      case 'reads':
        reading = socket.listen((_) {});
      case 'paused':
        reading = socket.listen((_) {})..pause();
      case 'resumes':
        reading = socket.listen((_) {})..pause();
        Timer(const Duration(milliseconds: 600), () => reading?.resume());
    }
    if (end == 'cancel') {
      Timer(const Duration(milliseconds: 300), () {
        reading ??= socket.listen((_) {});
        unawaited(reading!.cancel());
      });
    }
    await done.then<void>((_) {}, onError: (Object _) {});
    await reading?.cancel();
  }

  Future<(Application, ServerEngine)> serve() async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) => router
            ..ws(
              '/end',
              (socket, request) => handle(
                socket,
                request.uri.queryParameters['handler']!,
                request.uri.queryParameters['end']!,
              ),
              compress: false,
              maxPayloadBytes: 1 << 20,
              maxBufferedBytes: 256 << 10,
            )
            ..ws('/resume-after-close', (socket, request) async {
              // Pauses at once; resumes after closing from the server.
              final reading = socket.listen((m) => got.add('$m'.length))
                ..pause();
              await Future<void>.delayed(const Duration(milliseconds: 300));
              unawaited(socket.close(4001).then<void>((_) {}, onError: (_) {}));
              await Future<void>.delayed(const Duration(milliseconds: 80));
              reading.resume();
              await socket.done.then<void>((_) {}, onError: (Object _) {});
              await Future<void>.delayed(const Duration(milliseconds: 200));
              await reading.cancel();
              ended.complete(socket.closeCode);
            }, compress: false),
        )
        .create();
    await app.boot();
    final engine = ServerEngine(
      app,
      const ServeOptions(
        host: '127.0.0.1',
        port: 0,
        handleSignals: false,
        shutdownTimeout: Duration(seconds: 2),
      ),
      kernel: app.kernel,
      logger: Logger(handlers: [MemoryHandler()]),
    );
    await engine.start();
    return (app, engine);
  }

  /// [messages] text messages of 24 KiB, each in three fragments, in one
  /// buffer: held past the limit, the rest of a chunk left unparsed.
  Uint8List fragmented(int messages) {
    final all = BytesBuilder(copy: false);
    for (var i = 0; i < messages; i++) {
      final text = utf8.encode('$i:'.padRight(24 << 10, 'x'));
      final third = text.length ~/ 3;
      all
        ..add(RawWsClient.frame(0x1, text.sublist(0, third), fin: false))
        ..add(
          RawWsClient.frame(0x0, text.sublist(third, 2 * third), fin: false),
        )
        ..add(RawWsClient.frame(0x0, text.sublist(2 * third)));
    }
    return all.takeBytes();
  }

  Uint8List data(String hold) => switch (hold) {
    'tail' => fragmented(40),
    'held' => fragmented(3),
    // A message begun and never finished.
    _ => RawWsClient.frame(0x1, Uint8List(10 << 10), fin: false),
  };

  for (final end in ends) {
    for (final handler in handlers) {
      for (final hold in holds) {
        test('$end, handler $handler, guard holding $hold: the session ends '
            'and holds nothing', () async {
          final (app, engine) = await serve();
          try {
            final client = await RawWsClient.connect(
              engine.port!,
              '/end?handler=$handler&end=$end',
            );
            if (end == 'overflow') {
              client.pauseReading();
            }
            client.socket.add(data(hold));
            // TCP holds the client back when the handler does not read:
            // the flush does not complete then, and nothing more can be
            // sent until it does.
            final flushed = client.socket.flush().then<bool>(
              (_) => true,
              onError: (Object _) => false,
            );
            await flushed.timeout(
              const Duration(seconds: 1),
              onTimeout: () => false,
            );
            await Future<void>.delayed(const Duration(milliseconds: 200));
            Future<bool> sent(List<int> frame) async {
              if (!await flushed.timeout(
                const Duration(seconds: 10),
                onTimeout: () => false,
              )) {
                return false;
              }
              client.socket.add(frame);
              return true;
            }

            var reached = true;
            switch (end) {
              case 'client-close':
                reached = await sent(
                  RawWsClient.frame(0x8, const [0x03, 0xE8]),
                );
              case 'client-gone':
                client.socket.destroy();
              case 'stop':
                await engine.stop();
              case 'violation':
                // A frame of a reserved opcode.
                reached = await sent(RawWsClient.frame(0x3, const []));
              case 'cancel':
                // A handler that cancels keeps the socket: the client is
                // read on, and its close ends the session.
                await Future<void>.delayed(const Duration(milliseconds: 400));
                reached = await sent(
                  RawWsClient.frame(0x8, const [0x03, 0xE8]),
                );
            }
            // A handler that pauses for good keeps its session: while it
            // holds what the client sent, the client's close or going away
            // waits behind it, and while TCP is held back what the client
            // sends next is not read, or cannot even be sent (documented).
            // A violation the guard reads ends it all the same. The server
            // ending the session releases everything.
            final stuck =
                !reached ||
                (handler == 'paused' &&
                    (end == 'client-close' ||
                        end == 'client-gone' ||
                        (end == 'violation' && hold != 'assembling')));
            if (stuck) {
              await Future<void>.delayed(const Duration(seconds: 1));
              expect(engine.openWebSockets, 1, reason: 'kept while paused');
              await engine.stop();
            }
            final deadline = DateTime.now().add(const Duration(seconds: 15));
            while (engine.openWebSockets > 0 &&
                DateTime.now().isBefore(deadline)) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            expect(engine.openWebSockets, 0, reason: 'the session ended');
            // Within the grace the server's side of the socket closes (seen
            // once the client reads again).
            if (end == 'overflow') {
              client.resumeReading();
            }
            final closed = DateTime.now().add(const Duration(seconds: 8));
            while (!client.ended && DateTime.now().isBefore(closed)) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            if (end != 'client-gone') {
              expect(client.ended, isTrue, reason: 'the socket was closed');
            }
            client.socket.destroy();
            await expectWebSocketCountsReleased();
            expect(WebSocketGuardStats.toJson()['pinned'], 0);
            // No timer of the session is left either: the socket is gone.
            expect(await gracesWithin(const Duration(seconds: 7)), 0);
          } finally {
            await engine.stop();
            await app.shutdown();
          }
        }, timeout: const Timeout(Duration(seconds: 60)));
      }
    }
  }

  // After a close handshake the client's end destroys the socket at once,
  // its grace timer with it. After a violation the session ends only when
  // the grace (1 s) destroys the socket, the client's end notwithstanding:
  // bounded by it, not at once.
  for (final (end, frame, code, within) in [
    (
      'a close handshake',
      RawWsClient.frame(0x8, const [0x03, 0xE8]),
      1000,
      const Duration(milliseconds: 400),
    ),
    (
      'a violation',
      RawWsClient.frame(0x3, const []),
      1002,
      const Duration(milliseconds: 1500),
    ),
  ]) {
    test('a session that ends with $end keeps no grace timer once the '
        'client closed its connection (within $within)', () async {
      final (app, engine) = await serve();
      try {
        final client = await RawWsClient.connect(
          engine.port!,
          '/end?handler=reads&end=client-close',
        );
        client.send(0x1, utf8.encode('hello'));
        client.socket.add(frame);
        expect(await client.closeFrame(), code);
        await client.socket.close();
        final watch = Stopwatch()..start();
        expect(await gracesWithin(within), 0);
        expect(watch.elapsed, lessThanOrEqualTo(within + _slack));
        expect(engine.openWebSockets, 0);
        client.socket.destroy();
      } finally {
        await engine.stop();
        await app.shutdown();
      }
    });
  }

  test('a handler that resumes after the server closed gets none of what it '
      'had not read, and no close code', () async {
    final (app, engine) = await serve();
    try {
      final client = await RawWsClient.connect(
        engine.port!,
        '/resume-after-close',
      );
      client.socket.add(fragmented(40));
      await client.socket.flush().timeout(
        const Duration(seconds: 1),
        onTimeout: () {},
      );
      expect(await ended.future.timeout(const Duration(seconds: 15)), isNull);
      expect(got, isEmpty);
      client.socket.destroy();
      await expectWebSocketCountsReleased();
      expect(WebSocketGuardStats.toJson()['pinned'], 0);
    } finally {
      await engine.stop();
      await app.shutdown();
    }
  });
}

/// What a wait polled every 20 ms may run over its bound.
const Duration _slack = Duration(milliseconds: 100);
