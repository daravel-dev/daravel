import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
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
  // The rest of a chunk unparsed, sent in one write or in many small ones;
  // held over the limit; a message being assembled.
  const holds = ['tail', 'tail-pieces', 'held', 'assembling'];
  const ends = [
    'client-close',
    'client-gone',
    'server-close',
    'overflow',
    'stop',
    'violation',
    'cancel',
    // Two ends, one after the other.
    'violation+stop',
    'overflow+client-gone',
    'server-close+cancel',
  ];

  /// What a handler of [kind] does with [socket]; [end] is how the session
  /// ends (two ends joined by `+`), the handler's part of it.
  Future<void> handle(WebSocket socket, String kind, String end) async {
    StreamSubscription<dynamic>? reading;
    final done = socket.done;
    if (end.contains('server-close')) {
      Timer(const Duration(milliseconds: 300), () {
        unawaited(socket.close(4001).then<void>((_) {}, onError: (_) {}));
      });
    }
    if (end.contains('overflow')) {
      unawaited(() async {
        // Once what the client sent was held (and a rest left unparsed).
        await Future<void>.delayed(const Duration(milliseconds: 300));
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
    if (end.contains('cancel')) {
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
            // What is held is bounded by the message limit when it is
            // under 64 KiB: 16 KiB here, so the guard stops in the middle
            // of a chunk whatever size the system reads in (64 KiB on
            // Windows, more elsewhere), and the rest is left unparsed.
            ..ws(
              '/end16',
              (socket, request) => handle(
                socket,
                request.uri.queryParameters['handler']!,
                request.uri.queryParameters['end']!,
              ),
              compress: false,
              maxPayloadBytes: 16 << 10,
              maxBufferedBytes: 256 << 10,
            )
            ..ws(
              '/overflow-on-first',
              (socket, request) async {
                // Stops reading at the client's first message and sends
                // until the client, which does not read, overflows.
                late final StreamSubscription<dynamic> reading;
                reading = socket.listen((_) {
                  reading.pause();
                  unawaited(() async {
                    while (socket.readyState == WebSocket.open) {
                      socket.add(Uint8List(16 << 10));
                      await Future<void>.delayed(Duration.zero);
                    }
                  }());
                });
                await socket.done.then<void>((_) {}, onError: (Object _) {});
                await reading.cancel();
              },
              compress: false,
              maxPayloadBytes: 2 << 20,
              maxBufferedBytes: 64 << 10,
            )
            ..ws(
              '/close-on-first',
              (socket, request) async {
                // Closes at the client's first message, and reads on.
                final first = Completer<void>();
                final reading = socket.listen(
                  (_) => first.isCompleted ? null : first.complete(),
                  onDone: () => first.isCompleted ? null : first.complete(),
                );
                await first.future;
                await socket.close(1000, 'bye');
                await socket.done.then<void>((_) {}, onError: (Object _) {});
                await reading.cancel();
              },
              compress: false,
              maxPayloadBytes: 2 << 20,
            )
            ..ws(
              '/queue-then-close',
              (socket, request) async {
                // At the client's first message: 768 KiB queued, then the
                // close; it reads on (and drops) what the client sends.
                final first = Completer<void>();
                final reading = socket.listen(
                  (_) => first.isCompleted ? null : first.complete(),
                  onDone: () => first.isCompleted ? null : first.complete(),
                );
                await first.future;
                for (var i = 0; i < 12; i++) {
                  socket.add(Uint8List(64 << 10));
                }
                await socket.close(1000, 'bye');
                await socket.done.then<void>((_) {}, onError: (Object _) {});
                await reading.cancel();
              },
              compress: false,
              maxPayloadBytes: 8 << 20,
              maxBufferedBytes: 2 << 20,
            )
            ..ws('/close-then-cancel', (socket, request) async {
              // Closes at the client's first message, then cancels its
              // subscription while the close waits for the answer.
              final first = Completer<void>();
              late final StreamSubscription<dynamic> reading;
              reading = socket.listen(
                (_) => first.isCompleted ? null : first.complete(),
              );
              await first.future;
              unawaited(socket.close(1000).then<void>((_) {}, onError: (_) {}));
              await reading.cancel();
              await socket.done.then<void>((_) {}, onError: (Object _) {});
            }, compress: false)
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

  /// [messages] text messages of [size] bytes, each in three fragments, in
  /// one buffer: held past the limit, the rest of a chunk left unparsed.
  Uint8List fragmented(int messages, {int size = 24 << 10}) {
    final all = BytesBuilder(copy: false);
    for (var i = 0; i < messages; i++) {
      final text = utf8.encode('$i:'.padRight(size, 'x'));
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
    // To `/end16`: 12 KiB messages, held past 16 KiB in the first chunk.
    'tail' || 'tail-pieces' => fragmented(40, size: 12 << 10),
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
            WebSocketGuardStats.reset();
            final tail = hold.startsWith('tail');
            final route = tail ? '/end16' : '/end';
            final client = await RawWsClient.connect(
              engine.port!,
              '$route?handler=$handler&end=$end',
            );
            if (end.contains('overflow')) {
              client.pauseReading();
            }
            final bytes = data(hold);
            if (hold == 'tail-pieces') {
              for (var at = 0; at < bytes.length; at += 1024) {
                client.socket.add(
                  Uint8List.sublistView(
                    bytes,
                    at,
                    min(at + 1024, bytes.length),
                  ),
                );
              }
            } else {
              client.socket.add(bytes);
            }
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
            final compound = end.contains('+');
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
              case 'violation+stop':
                await sent(RawWsClient.frame(0x3, const []));
                await Future<void>.delayed(const Duration(milliseconds: 100));
                await engine.stop();
              case 'overflow+client-gone':
                // The handler's sends overflow from 300 ms on (the client
                // does not read), and the session is closed as a slow
                // client's; then the client goes.
                await Future<void>.delayed(const Duration(milliseconds: 600));
                client.socket.destroy();
              case 'server-close+cancel':
                // Both the handler's (300 ms): nothing from the client.
                break;
            }
            // A handler that pauses for good keeps its session: while it
            // holds what the client sent, the client's close or going away
            // waits behind it, and while TCP is held back what the client
            // sends next is not read, or cannot even be sent (documented).
            // A violation the guard reads ends it all the same. The server
            // ending the session releases everything; each pair of ends has
            // one from the server.
            final stuck =
                !compound &&
                (!reached ||
                    (handler == 'paused' &&
                        (end == 'client-close' ||
                            end == 'client-gone' ||
                            (end == 'violation' && hold != 'assembling'))));
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
            if (end.contains('overflow')) {
              client.resumeReading();
            }
            final closed = DateTime.now().add(const Duration(seconds: 8));
            while (!client.ended && DateTime.now().isBefore(closed)) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            if (!end.contains('client-gone')) {
              expect(client.ended, isTrue, reason: 'the socket was closed');
            }
            client.socket.destroy();
            await expectWebSocketCountsReleased();
            final counts = WebSocketGuardStats.toJson();
            expect(counts['pinned'], 0);
            if (tail && handler != 'reads') {
              // The cell is what it says: a rest of a chunk was left
              // unparsed, on every system.
              expect(counts['unparsedPeak'], greaterThan(0), reason: 'a tail');
            }
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

  // A client that sends on after this side closed, or after it was closed
  // as a slow client: what is read from then on is bounded (4 MiB, about
  // what can be in flight), then the socket is destroyed, instead of being
  // read and parsed at the client's rate for the whole grace.
  for (final (name, path, drains) in [
    ('the server closed', '/close-on-first', true),
    ('it was closed as a slow client', '/overflow-on-first', false),
  ]) {
    test('a client that sends 50 MiB after $name is read for at most 4 MiB '
        'more, then cut off', () async {
      final (app, engine) = await serve();
      try {
        final client = await RawWsClient.connect(engine.port!, path);
        if (!drains) {
          client.pauseReading();
        }
        final before = WebSocketGuardStats.toJson()['readWhileEnding'] ?? 0;
        // Sends on at once after its first message, without answering.
        client.send(0x1, utf8.encode('go'));
        final frame = RawWsClient.frame(0x2, Uint8List(64 << 10));
        final mebibyte = BytesBuilder(copy: false);
        for (var i = 0; i < 16; i++) {
          mebibyte.add(frame);
        }
        final batch = mebibyte.takeBytes();
        var gone = false;
        unawaited(
          client.socket.done.then<void>(
            (_) => gone = true,
            onError: (Object _) => gone = true,
          ),
        );
        var flushed = 0;
        for (var i = 0; i < 50 && !gone; i++) {
          try {
            client.socket.add(batch);
            await client.socket.flush().timeout(const Duration(seconds: 2));
            flushed += batch.length;
          } on Object {
            break; // Cut off, or held back.
          }
        }
        final read =
            (WebSocketGuardStats.toJson()['readWhileEnding'] ?? 0) - before;
        expect(flushed, lessThan(50 << 20), reason: 'cut off, not read on');
        // Only up to the bound is taken from what the system hands over.
        expect(read, lessThanOrEqualTo(4 << 20));
        client.socket.destroy();
        expect(await gracesWithin(const Duration(seconds: 2)), 0);
      } finally {
        await engine.stop();
        await app.shutdown();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));
  }

  test('200 sessions ended by a violation whose clients cut the connection '
      'leave no grace timer', () async {
    final (app, engine) = await serve();
    try {
      for (var i = 0; i < 200; i++) {
        final client = await RawWsClient.connect(
          engine.port!,
          '/end?handler=reads&end=client-close',
        );
        client.socket.add(RawWsClient.frame(0x3, const []));
        await client.socket.flush();
        // Cut 2 ms after the violation, its close frame unread.
        await Future<void>.delayed(const Duration(milliseconds: 2));
        client.socket.destroy();
      }
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (engine.openWebSockets > 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(engine.openWebSockets, 0);
      // Every socket is gone: no timer of theirs is left (the grace is
      // 1 s; this looks well before).
      expect(await gracesWithin(const Duration(milliseconds: 300)), 0);
      await expectWebSocketCountsReleased();
    } finally {
      await engine.stop();
      await app.shutdown();
    }
  }, timeout: const Timeout(Duration(seconds: 120)));

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

  // The table of how a session ends (closing, a violation, the session
  // over), cell by cell; the open state is the matrix above.
  group('closing table', () {
    const bound = 4 << 20;

    /// Sends [frames] binary frames of 64 KiB, one message in fragments,
    /// each flushed within 2 s; how many went out before one did not.
    Future<int> sendFragmented(RawWsClient client, int frames) async {
      final payload = Uint8List(64 << 10);
      var sent = 0;
      for (var i = 0; i < frames; i++) {
        final opcode = i == 0 ? 0x2 : 0x0;
        try {
          client.socket.add(
            RawWsClient.frame(opcode, payload, fin: i == frames - 1),
          );
          await client.socket.flush().timeout(const Duration(seconds: 2));
        } on Object {
          break;
        }
        sent++;
      }
      return sent;
    }

    /// The data bytes and the close code the client got, until the close
    /// or until nothing came for 10 s.
    Future<(int, int?)> drain(RawWsClient client) async {
      var bytes = 0;
      while (true) {
        final WsFrame frame;
        try {
          frame = await client.next();
        } on Object {
          return (bytes, null);
        }
        if (frame.opcode == 0x8) {
          return (bytes, frame.closeCode);
        }
        if (frame.opcode < 0x8) {
          bytes += frame.payload.length;
        }
      }
    }

    int readSinceDone() => WebSocketGuardStats.toJson()['readWhileEnding'] ?? 0;
    int boundStops() => WebSocketGuardStats.toJson()['boundStops'] ?? 0;

    for (final (name, paused, waitFirst) in [
      ('while the client reads', false, false),
      ('while the client does not read, then reads', true, false),
      ('with the close already queued', true, true),
    ]) {
      test(
        'closing x past the bound ($name): the client gets what was '
        'queued and the close, as on main; reading stops, no reset',
        () async {
          final (app, engine) = await serve();
          try {
            final client = await RawWsClient.connect(
              engine.port!,
              '/queue-then-close',
            );
            if (paused) {
              client.pauseReading();
            }
            final before = readSinceDone();
            client.send(0x1, utf8.encode('go'));
            if (waitFirst) {
              await Future<void>.delayed(const Duration(milliseconds: 200));
            }
            // 5 MiB in fragments, under the message limit: past the bound.
            await sendFragmented(client, 80);
            if (paused) {
              client.resumeReading();
            }
            final (bytes, close) = await drain(client);
            expect(bytes, 12 * (64 << 10), reason: 'everything queued');
            expect(close, 1000);
            expect(readSinceDone() - before, lessThanOrEqualTo(bound));
            client.socket.destroy();
          } finally {
            await engine.stop();
            await app.shutdown();
          }
        },
        timeout: const Timeout(Duration(seconds: 60)),
      );
    }

    test('closing x past the bound, the client sending on: the graces end '
        'the socket within 11 s of the close', () async {
      final (app, engine) = await serve();
      try {
        final client = await RawWsClient.connect(
          engine.port!,
          '/close-on-first',
        );
        final watch = Stopwatch()..start();
        client.send(0x1, utf8.encode('go'));
        final payload = RawWsClient.frame(0x2, Uint8List(64 << 10));
        while (!client.ended && watch.elapsed < const Duration(seconds: 20)) {
          try {
            client.socket.add(payload);
            await client.socket.flush().timeout(
              const Duration(milliseconds: 500),
            );
          } on TimeoutException {
            // Held back: the server stopped reading. Keep trying.
          } on Object {
            break;
          }
        }
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (engine.openWebSockets > 0 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(engine.openWebSockets, 0);
        expect(await gracesWithin(const Duration(seconds: 13)), 0);
        expect(
          watch.elapsed,
          lessThan(const Duration(seconds: 11) + const Duration(seconds: 2)),
        );
        client.socket.destroy();
      } finally {
        await engine.stop();
        await app.shutdown();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('closing x sub.cancel(): the client is read on, its close and its '
        'end are seen and end the session', () async {
      final (app, engine) = await serve();
      try {
        final client = await RawWsClient.connect(
          engine.port!,
          '/close-then-cancel',
        );
        final before = readSinceDone();
        client.send(0x1, utf8.encode('go'));
        expect(await client.closeFrame(), 1000);
        // What it still had to send before its answer: read on, not cut.
        final payload = RawWsClient.frame(0x2, Uint8List(64 << 10));
        for (var i = 0; i < 16; i++) {
          client.socket.add(payload);
          await client.socket.flush().timeout(const Duration(seconds: 2));
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(
          readSinceDone() - before,
          greaterThanOrEqualTo(16 * (64 << 10)),
          reason: 'TCP still read after the cancel',
        );
        client.send(0x8, const [0x03, 0xE8]);
        await client.socket.flush();
        await client.socket.close();
        final watch = Stopwatch()..start();
        while (engine.openWebSockets > 0 &&
            watch.elapsed < const Duration(seconds: 3)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(engine.openWebSockets, 0, reason: 'ended by the answer');
        expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
        client.socket.destroy();
      } finally {
        await engine.stop();
        await app.shutdown();
      }
    });

    test('closing, then a violation: one count, never started again; it '
        'stops at the bound', () async {
      final (app, engine) = await serve();
      try {
        final client = await RawWsClient.connect(
          engine.port!,
          '/close-on-first',
        );
        final before = readSinceDone();
        client.send(0x1, utf8.encode('go'));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        // 3.875 MiB, a frame of a reserved opcode, then 4 MiB more.
        final payload = Uint8List(64 << 10);
        Future<void> frames(int n) async {
          for (var i = 0; i < n; i++) {
            try {
              client.socket.add(RawWsClient.frame(0x2, payload));
              await client.socket.flush().timeout(const Duration(seconds: 2));
            } on Object {
              return;
            }
          }
        }

        await frames(62);
        client.socket.add(RawWsClient.frame(0x3, const []));
        await frames(64);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(readSinceDone() - before, bound, reason: 'one count');
        client.socket.destroy();
      } finally {
        await engine.stop();
        await app.shutdown();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a violation x past the bound: reading stops at the bound, the '
        'close frame still goes out', () async {
      final (app, engine) = await serve();
      try {
        final client = await RawWsClient.connect(
          engine.port!,
          '/end?handler=reads&end=client-close',
        );
        final before = readSinceDone();
        final stopsBefore = boundStops();
        // The violation and 6 MiB after it, as fast as the client writes:
        // on Linux and macOS much of it comes in the violation's own chunk,
        // which counts too.
        client.socket.add(RawWsClient.frame(0x3, const []));
        final payload = RawWsClient.frame(0x2, Uint8List(64 << 10));
        var sentAll = true;
        for (var i = 0; i < 96; i++) {
          try {
            client.socket.add(payload);
            await client.socket.flush().timeout(const Duration(seconds: 2));
          } on Object {
            // The server stopped reading (TCP fills) or the grace ended
            // the socket; which one is asserted below.
            sentAll = false;
            break;
          }
        }
        expect(await client.closeFrame(), 1002);
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final counted = readSinceDone() - before;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        expect(readSinceDone() - before, counted, reason: 'reading stopped');
        final stopped = boundStops() - stopsBefore;
        expect(stopped, lessThanOrEqualTo(1));
        if (stopped == 1) {
          // Paused at the bound: exactly the bound was read.
          expect(counted, bound);
        } else {
          // The grace ended the socket first: under the bound, and the
          // client could not send it all (6 MiB read without reaching the
          // bound would mean bytes read and not counted).
          expect(counted, lessThan(bound));
          expect(sentAll, isFalse, reason: 'all sent, under the bound');
        }
        client.socket.destroy();
      } finally {
        await engine.stop();
        await app.shutdown();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('session over x past the bound: the socket is destroyed at the '
        'bound, not read on', () async {
      final (app, engine) = await serve();
      try {
        final client = await RawWsClient.connect(
          engine.port!,
          '/close-on-first',
        );
        final before = readSinceDone();
        client.send(0x1, utf8.encode('go'));
        expect(await client.closeFrame(), 1000);
        // The handshake completes: the session is over.
        client.send(0x8, const [0x03, 0xE8]);
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (engine.openWebSockets > 0 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        final payload = RawWsClient.frame(0x2, Uint8List(64 << 10));
        var flushed = 0;
        for (var i = 0; i < 96 && !client.ended; i++) {
          try {
            client.socket.add(payload);
            await client.socket.flush().timeout(const Duration(seconds: 2));
            flushed += payload.length;
          } on Object {
            break; // Cut off.
          }
        }
        final gone = DateTime.now().add(const Duration(seconds: 5));
        while (!client.ended && DateTime.now().isBefore(gone)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(client.ended, isTrue, reason: 'destroyed, not paused');
        expect(flushed, lessThan(96 * payload.length));
        expect(readSinceDone() - before, lessThanOrEqualTo(bound));
        expect(await gracesWithin(const Duration(seconds: 2)), 0);
      } finally {
        await engine.stop();
        await app.shutdown();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('a violation x the client sending on: the graces end the socket '
        'within 11 s of the close', () async {
      final (app, engine) = await serve();
      try {
        final client = await RawWsClient.connect(
          engine.port!,
          '/end?handler=reads&end=client-close',
        );
        final before = readSinceDone();
        final watch = Stopwatch()..start();
        client.socket.add(RawWsClient.frame(0x3, const []));
        final payload = RawWsClient.frame(0x2, Uint8List(64 << 10));
        while (!client.ended && watch.elapsed < const Duration(seconds: 20)) {
          try {
            client.socket.add(payload);
            await client.socket.flush().timeout(
              const Duration(milliseconds: 500),
            );
          } on TimeoutException {
            // Held back: the server stopped reading. Keep trying.
          } on Object {
            break;
          }
        }
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (engine.openWebSockets > 0 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(engine.openWebSockets, 0);
        expect(await gracesWithin(const Duration(seconds: 13)), 0);
        expect(
          watch.elapsed,
          lessThan(const Duration(seconds: 11) + const Duration(seconds: 2)),
        );
        expect(readSinceDone() - before, lessThanOrEqualTo(bound));
        client.socket.destroy();
      } finally {
        await engine.stop();
        await app.shutdown();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('closed as a slow client x the client sending on: the graces end '
        'the socket within 11 s of the close', () async {
      final (app, engine) = await serve();
      try {
        final client = await RawWsClient.connect(
          engine.port!,
          '/overflow-on-first',
        );
        // Never reads: what is sent to it piles up and it is closed as a
        // slow client.
        client.pauseReading();
        final before = readSinceDone();
        final watch = Stopwatch()..start();
        client.send(0x1, utf8.encode('go'));
        final payload = RawWsClient.frame(0x2, Uint8List(64 << 10));
        while (watch.elapsed < const Duration(seconds: 20)) {
          try {
            client.socket.add(payload);
            await client.socket.flush().timeout(
              const Duration(milliseconds: 500),
            );
          } on TimeoutException {
            // Held back: the server stopped reading. Keep trying.
          } on Object {
            break; // The socket is gone.
          }
          if (engine.openWebSockets == 0) {
            break;
          }
        }
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (engine.openWebSockets > 0 && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(engine.openWebSockets, 0);
        expect(await gracesWithin(const Duration(seconds: 13)), 0);
        expect(
          watch.elapsed,
          lessThan(const Duration(seconds: 11) + const Duration(seconds: 2)),
        );
        expect(readSinceDone() - before, lessThanOrEqualTo(bound));
        client.socket.destroy();
      } finally {
        await engine.stop();
        await app.shutdown();
      }
    }, timeout: const Timeout(Duration(seconds: 60)));

    // The handler cancels its subscription 300 ms in (`cancel`); the slow
    // client never reads, so it is closed as one (`overflow`).
    final violation = RawWsClient.frame(0x3, const []);
    for (final (name, path, paused, prelude) in [
      (
        'a violation x sub.cancel()',
        '/end?handler=reads&end=cancel',
        false,
        [violation],
      ),
      (
        'closed as a slow client x a violation',
        '/overflow-on-first',
        true,
        [RawWsClient.frame(0x1, utf8.encode('go')), violation],
      ),
      (
        'closed as a slow client x sub.cancel()',
        '/end?handler=reads&end=overflow+cancel',
        true,
        <Uint8List>[],
      ),
    ]) {
      test('$name, the client sending on: what is read stays within the '
          'bound and the socket ends within 11 s', () async {
        final (app, engine) = await serve();
        try {
          final client = await RawWsClient.connect(engine.port!, path);
          if (paused) {
            client.pauseReading();
          }
          final before = readSinceDone();
          final watch = Stopwatch()..start();
          for (final frame in prelude) {
            client.socket.add(frame);
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
          final payload = RawWsClient.frame(0x2, Uint8List(64 << 10));
          while (watch.elapsed < const Duration(seconds: 20) &&
              engine.openWebSockets > 0) {
            try {
              client.socket.add(payload);
              await client.socket.flush().timeout(
                const Duration(milliseconds: 500),
              );
            } on TimeoutException {
              // Held back: the server stopped reading. Keep trying.
            } on Object {
              break; // The socket is gone.
            }
          }
          final deadline = DateTime.now().add(const Duration(seconds: 20));
          while (engine.openWebSockets > 0 &&
              DateTime.now().isBefore(deadline)) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          }
          expect(engine.openWebSockets, 0);
          expect(await gracesWithin(const Duration(seconds: 13)), 0);
          expect(
            watch.elapsed,
            lessThan(const Duration(seconds: 11) + const Duration(seconds: 2)),
          );
          expect(readSinceDone() - before, lessThanOrEqualTo(bound));
          client.socket.destroy();
        } finally {
          await engine.stop();
          await app.shutdown();
        }
      }, timeout: const Timeout(Duration(seconds: 60)));
    }
  });
}

/// What a wait polled every 20 ms may run over its bound.
const Duration _slack = Duration(milliseconds: 100);
