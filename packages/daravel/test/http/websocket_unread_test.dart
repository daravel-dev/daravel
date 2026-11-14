import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/raw_ws_client.dart';

/// A WebSocket whose handler does not read yet (it does async work first)
/// or never reads: the server reads the client on, holds what it sends in
/// order, and sees its close or its going away.
void main() {
  late Application app;
  late ServerEngine engine;
  late MemoryHandler log;

  /// What each handler saw: its messages, then `done:<closeCode>`.
  final seen = <String, List<String>>{};

  Future<void> listenLater(WebSocket socket, Request request) async {
    final id = request.uri.queryParameters['id']!;
    final into = seen[id] = [];
    await Future<void>.delayed(
      Duration(
        milliseconds: int.parse(request.uri.queryParameters['delay'] ?? '300'),
      ),
    );
    final done = Completer<void>();
    late final StreamSubscription<dynamic> reading;
    final random = Random(
      int.parse(request.uri.queryParameters['seed'] ?? '0'),
    );
    reading = socket.listen((message) {
      into.add(
        message is String ? message : 'bytes:${(message as List).length}',
      );
      // Pauses the reading now and then, as a slow handler does.
      if (request.uri.queryParameters['pauses'] == '1' &&
          random.nextInt(4) == 0) {
        reading.pause(Future<void>.delayed(const Duration(milliseconds: 5)));
      }
    }, onDone: done.complete);
    await done.future;
    await reading.cancel();
    into.add('done:${socket.closeCode}');
  }

  Future<void> neverListen(WebSocket socket, Request request) async {
    final into = seen[request.uri.queryParameters['id']!] = [];
    socket.add('hello');
    await socket.done;
    into.add('done:${socket.closeCode}');
  }

  setUp(() async {
    seen.clear();
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) => router
            // Many PINGs between fragments in the random test.
            ..ws(
              '/later',
              listenLater,
              compress: false,
              controlFrameBurst: 1 << 30,
            )
            ..ws('/never', neverListen, compress: false)
            ..ws('/slow-reader', (socket, request) async {
              // Listens at once, and takes a while over each message.
              final into = seen[request.uri.queryParameters['id']!] = [];
              final each = Duration(
                milliseconds: int.parse(request.uri.queryParameters['ms']!),
              );
              await for (final message in socket) {
                into.add(message as String);
                await Future<void>.delayed(each);
              }
              into.add('done:${socket.closeCode}');
            }, compress: false)
            ..ws('/pause-first', (socket, request) async {
              // Pauses for a long while after the first message.
              final into = seen[request.uri.queryParameters['id']!] = [];
              final done = Completer<void>();
              late final StreamSubscription<dynamic> reading;
              reading = socket.listen((message) {
                into.add(message as String);
                if (into.length == 1) {
                  reading.pause(
                    Future<void>.delayed(const Duration(seconds: 8)),
                  );
                }
              }, onDone: done.complete);
              await done.future;
              await reading.cancel();
              into.add('done:${socket.closeCode}');
            }, compress: false)
            ..ws('/reenter', (socket, request) async {
              // Pauses and resumes inside its own onData.
              final into = seen[request.uri.queryParameters['id']!] = [];
              final done = Completer<void>();
              var depth = 0;
              late final StreamSubscription<dynamic> reading;
              reading = socket.listen((message) {
                depth++;
                if (depth > 1) {
                  into.add('nested');
                }
                into.add(message as String);
                if (into.length == 1) {
                  // The rest waits meanwhile.
                  reading.pause(
                    Future<void>.delayed(const Duration(milliseconds: 300)),
                  );
                } else {
                  reading
                    ..pause()
                    ..resume();
                }
                depth--;
              }, onDone: done.complete);
              await done.future;
              await reading.cancel();
              into.add('done:${socket.closeCode}');
            }, compress: false)
            ..ws('/loop', (socket, request) async {
              // Writes in a loop, never listening.
              final into = seen[request.uri.queryParameters['id']!] = [];
              while (socket.readyState == WebSocket.open) {
                socket.add('tick');
                await Future<void>.delayed(const Duration(milliseconds: 100));
              }
              into.add('done:${socket.closeCode}');
            }, compress: false)
            ..ws('/self-close', (socket, request) async {
              // Closes itself; the client never answers.
              final into = seen[request.uri.queryParameters['id']!] = [];
              socket.listen((_) {});
              await socket.close(4001, 'bye');
              await socket.done;
              into.add('done:${socket.closeCode}');
              await Future<void>.delayed(const Duration(seconds: 2));
              into.add('later:${socket.closeCode}');
            }, compress: false)
            ..ws(
              '/slow-code',
              (socket, request) async {
                final into = seen[request.uri.queryParameters['id']!] = [];
                socket.listen((_) {});
                while (socket.readyState == WebSocket.open) {
                  socket.add(Uint8List(64 << 10));
                  await Future<void>.delayed(Duration.zero);
                }
                await socket.done;
                into.add('done:${socket.closeCode}');
                await Future<void>.delayed(const Duration(seconds: 2));
                into.add('later:${socket.closeCode}');
              },
              compress: false,
              maxBufferedBytes: 1 << 20,
              slowClientCode: 4100,
            )
            ..ws('/returns-after', (socket, request) async {
              // Returns after `ms` without ever listening: the server's
              // drain starts 5 s after that.
              await Future<void>.delayed(
                Duration(
                  milliseconds: int.parse(request.uri.queryParameters['ms']!),
                ),
              );
            }, compress: false)
            ..ws('/returns', (socket, _) {
              socket.add('hello');
            }, compress: false)
            ..ws(
              '/slow',
              (socket, _) async {
                // Writes until the client, which does not read, is closed.
                while (socket.readyState == WebSocket.open) {
                  socket.add(Uint8List(64 << 10));
                  await Future<void>.delayed(Duration.zero);
                }
              },
              compress: false,
              maxBufferedBytes: 1 << 20,
            )
            ..ws(
              '/pings',
              (socket, _) {
                socket.listen((_) {});
              },
              compress: false,
              maxBufferedBytes: 65536,
              controlFrameBurst: 1 << 30,
              controlFramesPerSecond: 1 << 30,
            ),
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

  Future<int> sessionEndsWithin(Duration limit) async {
    final watch = Stopwatch()..start();
    while (engine.openWebSockets > 0 && watch.elapsed < limit) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return watch.elapsedMilliseconds;
  }

  /// A connection whose session has started (the server counts it a
  /// moment after its 101).
  Future<RawWsClient> open(String path) async {
    final client = await RawWsClient.connect(engine.port!, path);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (engine.openWebSockets == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(engine.openWebSockets, 1);
    return client;
  }

  void expectNoErrors() => expect(
    log.records.where((r) => r.level.index >= LogLevel.error.index),
    isEmpty,
  );

  /// The three ends a client can make.
  final ends = <String, Future<void> Function(RawWsClient client)>{
    'a close frame (4000)': (client) async {
      client.send(0x8, [0x0F, 0xA0, ...utf8.encode('bye')]);
    },
    'a FIN': (client) => client.socket.close(),
    'a reset': (client) async {
      // Unread data on the client's side makes its close a reset.
      client.pauseReading();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      client.socket.destroy();
    },
  };

  for (final MapEntry(key: how, value: end) in ends.entries) {
    group('three messages then $how', () {
      Future<RawWsClient> sendThree(String path) async {
        final client = await open(path);
        for (final text in ['one', 'two', 'three']) {
          client.send(0x1, utf8.encode(text));
        }
        await end(client);
        return client;
      }

      final code = how.contains('4000') ? '4000' : '1006';

      test('(i) a handler that listens 300 ms later gets the three, then '
          'done', () async {
        final client = await sendThree('/later?id=i&delay=300');
        await sessionEndsWithin(const Duration(seconds: 3));
        expect(engine.openWebSockets, 0);
        // A reset can lose what the client sent last; a FIN or a close
        // cannot.
        if (how != 'a reset') {
          expect(seen['i'], ['one', 'two', 'three', 'done:$code']);
        } else {
          expect(seen['i']!.last, 'done:1006');
        }
        client.socket.destroy();
        expectNoErrors();
      });

      test('(ii) a handler that never listens: the session ends after the '
          'wait, with the client\'s code', () async {
        final client = await sendThree('/never?id=ii');
        final ms = await sessionEndsWithin(const Duration(seconds: 10));
        printOnFailure('ended after $ms ms');
        expect(engine.openWebSockets, 0);
        expect(ms, lessThan(7500), reason: 'the wait (5 s) and the grace');
        expect(seen['ii'], ['done:$code']);
        if (how == 'a close frame (4000)') {
          expect(await client.closeFrame(), 4000, reason: 'answered in kind');
        }
        client.socket.destroy();
        expectNoErrors();
      });

      test('(iii) a handler that returned: the session ends when the server '
          'reads for it, 5 s after the handler returned', () async {
        final client = await sendThree('/returns');
        final ms = await sessionEndsWithin(const Duration(seconds: 10));
        printOnFailure('ended after $ms ms');
        expect(engine.openWebSockets, 0);
        expect(ms, lessThan(7000));
        client.socket.destroy();
        expectNoErrors();
      });
    });
  }

  group('a handler that listens and reads slowly loses nothing', () {
    const five = ['m1', 'm2', 'm3', 'm4', 'm5'];

    for (final (how, code) in [
      ('a close (1000)', 1000),
      ('a TCP drop', 1006),
    ]) {
      test('(a/b) 2 s per message, five messages then $how: all five, then '
          'done with $code', () async {
        final id = 'slow-$code';
        final client = await open('/slow-reader?id=$id&ms=2000');
        // One every 300 ms: the later ones arrive while the reader is busy
        // (paused) with an earlier one.
        for (final text in five) {
          client.send(0x1, utf8.encode(text));
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        if (code == 1000) {
          client.send(0x8, const [0x03, 0xE8]);
        } else {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          await client.socket.close();
        }
        final ms = await sessionEndsWithin(const Duration(seconds: 20));
        printOnFailure('ended after $ms ms; seen ${seen[id]}');
        expect(seen[id], [...five, 'done:$code']);
        client.socket.destroy();
        expectNoErrors();
      });
    }

    test('(c) a listener paused for 8 s after the first message: nothing is '
        'lost', () async {
      final client = await open('/pause-first?id=pause');
      for (final text in five) {
        client.send(0x1, utf8.encode(text));
      }
      client.send(0x8, const [0x03, 0xE8]);
      final ms = await sessionEndsWithin(const Duration(seconds: 20));
      printOnFailure('ended after $ms ms; seen ${seen['pause']}');
      expect(seen['pause'], [...five, 'done:1000']);
      client.socket.destroy();
      expectNoErrors();
    });

    test('a listener that pauses and resumes inside its onData gets each '
        'message once, in order, never nested', () async {
      final client = await open('/reenter?id=reenter');
      // Spread out, so they wait while the first message pauses the
      // listener (300 ms), and are handed on one by one afterwards.
      for (final text in five) {
        client.send(0x1, utf8.encode(text));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      client.send(0x8, const [0x03, 0xE8]);
      await sessionEndsWithin(const Duration(seconds: 10));
      expect(seen['reenter'], [...five, 'done:1000']);
      client.socket.destroy();
      expectNoErrors();
    });
  });

  test(
    'a handler that writes in a loop while readyState is open, never '
    'listening: the loop ends once the client closed, with its code',
    () async {
      final client = await open('/loop?id=loop');
      await client.next(); // a tick
      client.send(0x8, [0x0F, 0xA0]); // 4000
      final ms = await sessionEndsWithin(const Duration(seconds: 10));
      printOnFailure('ended after $ms ms');
      expect(engine.openWebSockets, 0);
      expect(ms, lessThan(7500));
      expect(seen['loop'], ['done:4000']);
      client.socket.destroy();
      expectNoErrors();
    },
  );

  test('a client that sends nothing and goes away from a handler that '
      'never listens: the session ends at once', () async {
    final client = await open('/never?id=n');
    await client.next(); // hello
    await client.socket.close();
    final ms = await sessionEndsWithin(const Duration(seconds: 3));
    expect(engine.openWebSockets, 0);
    expect(ms, lessThan(1000));
    expect(seen['n'], ['done:1006']);
  });

  test(
    'random messages, a handler that starts listening at a random '
    'moment and pauses at random: each message arrives once, in order',
    () async {
      final random = Random(20261113);
      for (var round = 0; round < 12; round++) {
        final id = 'r$round';
        final delay = [0, 20, 150, 400][random.nextInt(4)];
        final client = await open(
          '/later?id=$id&delay=$delay&pauses=1&seed=$round',
        );
        final sent = <String>[];
        final count = 5 + random.nextInt(40);
        for (var i = 0; i < count; i++) {
          // Up to 24 KiB, beyond 64 KiB in all: the client is held back by
          // TCP for a while in the larger rounds.
          final text = '$i:${'x' * random.nextInt(24 << 10)}';
          sent.add(text);
          if (text.length > 8 && random.nextBool()) {
            final cut = 1 + random.nextInt(text.length - 1);
            final bytes = utf8.encode(text);
            client
              ..send(0x1, bytes.sublist(0, cut), fin: false)
              ..send(0x9, utf8.encode('p'))
              ..send(0x0, bytes.sublist(cut));
          } else {
            client.send(0x1, utf8.encode(text));
          }
        }
        client.send(0x8, const [0x03, 0xE8]);
        await sessionEndsWithin(const Duration(seconds: 10));
        printOnFailure('round $round: $count messages, delay $delay ms');
        expect(seen[id], [...sent, 'done:1000']);
        client.socket.destroy();
      }
      expectNoErrors();
    },
  );

  group('a socket this side closed and the client never answered', () {
    // closeCode is the code the client sent: none here. The end of the
    // connection afterwards does not make it 1006.
    for (final (route, why) in [
      ('self-close', 'the application closed with 4001'),
      ('slow-code', 'closed as a slow client with 4100'),
    ]) {
      test('$why: no code, before and after the connection ends', () async {
        final client = await open('/$route?id=$route');
        client.pauseReading();
        final deadline = DateTime.now().add(const Duration(seconds: 15));
        while ((seen[route]?.length ?? 0) < 2 &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(seen[route], ['done:null', 'later:null']);
        client.socket.destroy();
      }, timeout: const Timeout(Duration(seconds: 30)));
    }
  });

  group('slow clients end their session with the 1 s grace', () {
    test('the application\'s queue overflows', () async {
      final client = await open('/slow');
      client.pauseReading();
      final ms = await sessionEndsWithin(const Duration(seconds: 10));
      printOnFailure('ended after $ms ms');
      expect(engine.openWebSockets, 0);
      expect(ms, lessThan(2500));
      client.socket.destroy();
    });

    test('the guard\'s queue (its PONGs) overflows', () async {
      final client = await open('/pings');
      client.pauseReading();
      final ping = RawWsClient.frame(0x9, Uint8List(125));
      final burst = BytesBuilder();
      for (var i = 0; i < 4000; i++) {
        burst.add(ping);
      }
      final bytes = burst.takeBytes();
      // PINGs until the guard's queue overflows: how many that takes
      // depends on how much the system's socket buffers take in first
      // (more on Linux), so the client sends until the server says so.
      bool overflowed() =>
          log.records.any((r) => r.message.contains('read too slowly'));
      for (var i = 0; i < 64 && !overflowed() && !client.ended; i++) {
        try {
          client.socket.add(bytes);
          await client.socket.flush().timeout(const Duration(seconds: 1));
        } on Object {
          break; // the server stopped reading or destroyed the socket
        }
      }
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (!overflowed() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(overflowed(), isTrue, reason: 'the queue overflowed');
      // From the overflow, the session ends within the grace.
      final ms = await sessionEndsWithin(const Duration(seconds: 10));
      printOnFailure('ended $ms ms after the overflow');
      expect(engine.openWebSockets, 0);
      expect(ms, lessThan(2500));
      client.socket.destroy();
    });
  });

  group('a handler that does not read while what is held is full', () {
    /// Every frame the server sent, until the connection ended.
    Future<List<WsFrame>> framesUntilEnd(RawWsClient client) async {
      final frames = <WsFrame>[];
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (DateTime.now().isBefore(deadline)) {
        try {
          frames.add(await client.next());
        } on TimeoutException {
          break;
        }
        if (client.ended) {
          // What arrived before the end, then stop.
          while (true) {
            try {
              frames.add(
                await client.next().timeout(const Duration(milliseconds: 50)),
              );
            } on TimeoutException {
              break;
            }
          }
          break;
        }
      }
      return frames;
    }

    // Which close a session ends with depends on where the client's CLOSE
    // is when the server holds TCP back: read already (it came in what the
    // server read up to the bound), the client's code; not read (it came
    // after), 1008. The client below decides which by its writes.
    for (final size in [65536, 70000]) {
      for (final route in ['never', 'loop']) {
        test('$size bytes, then (after the server held TCP back) CLOSE(4000) '
            'and FIN, to /$route: the server ends the session with 1008 '
            'after the unread wait', () async {
          final id = 'b-$route-$size';
          final client = await open('/$route?id=$id');
          client.send(0x2, Uint8List(size));
          await client.socket.flush();
          // The server reads past its bound and holds TCP back: the CLOSE
          // written now waits in TCP, unread.
          await Future<void>.delayed(const Duration(milliseconds: 500));
          client.send(0x8, const [0x0F, 0xA0]); // 4000
          await client.socket.flush();
          await client.socket.close();
          final ms = await sessionEndsWithin(const Duration(seconds: 9));
          expect(engine.openWebSockets, 0, reason: 'the session ended');
          expect(ms, lessThan(8000));
          expect(seen[id], ['done:1008']);
          final warning = log.records.where(
            (r) => r.message.contains('did not read'),
          );
          expect(warning, hasLength(1));
          expect(warning.single.context['path'], '/$route');
          client.socket.destroy();
        });
      }
    }

    for (final route in ['never', 'loop']) {
      test('60 000 bytes and CLOSE(4000) in one write, then FIN, to /$route: '
          'the close is read before any hold, and the session ends with the '
          "client's code after the unread wait", () async {
        final id = 'b4000-$route';
        final client = await open('/$route?id=$id');
        client.socket.add([
          ...RawWsClient.frame(0x2, Uint8List(60000)),
          ...RawWsClient.frame(0x8, const [0x0F, 0xA0]),
        ]);
        await client.socket.flush();
        await client.socket.close();
        final ms = await sessionEndsWithin(const Duration(seconds: 9));
        expect(engine.openWebSockets, 0, reason: 'the session ended');
        expect(ms, lessThan(8000));
        expect(seen[id], ['done:4000']);
        expect(
          log.records.where((r) => r.message.contains('did not read')),
          isEmpty,
        );
        client.socket.destroy();
      });
    }

    test('a listen at 4.9 s after it filled gets everything, in order, and '
        'no 1008', () async {
      final client = await open('/later?id=b-late&delay=4900');
      final messages = [for (var i = 0; i < 100; i++) 'm$i'.padRight(1024)];
      for (final message in messages) {
        client.send(0x1, utf8.encode(message));
      }
      client.send(0x8, const [0x03, 0xE8]);
      await sessionEndsWithin(const Duration(seconds: 12));
      expect(seen['b-late'], [...messages, 'done:1000']);
      expect(
        log.records.where((r) => r.message.contains('did not read')),
        isEmpty,
      );
      client.socket.destroy();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test(
      "the server's drain, 5 s after the handler returned, comes first: "
      'it reads what was held, and the session goes on to its own close',
      () async {
        // The handler returns at once; the client fills what is held 500 ms
        // later, so the unread wait would end 500 ms after the drain starts.
        final client = await open('/returns-after?ms=0');
        await Future<void>.delayed(const Duration(milliseconds: 500));
        client.send(0x2, Uint8List(100000));
        await Future<void>.delayed(const Duration(seconds: 7));
        expect(engine.openWebSockets, 1, reason: 'drained, not ended');
        client.send(0x8, const [0x03, 0xE8]);
        final frames = await framesUntilEnd(client);
        final closes = frames.where((f) => f.opcode == 0x8).toList();
        expect(closes, hasLength(1));
        expect(closes.single.closeCode, 1000);
        expect(
          log.records.where((r) => r.message.contains('did not read')),
          isEmpty,
        );
        client.socket.destroy();
      },
      timeout: const Timeout(Duration(seconds: 30)),
    );

    test('the unread wait comes first (the handler returned 3 s in): one '
        '1008, one close, and the drain finds the session closing', () async {
      final client = await open('/returns-after?ms=3000');
      client.send(0x2, Uint8List(100000));
      final frames = await framesUntilEnd(client);
      final closes = frames.where((f) => f.opcode == 0x8).toList();
      expect(closes, hasLength(1));
      expect(closes.single.closeCode, 1008);
      await sessionEndsWithin(const Duration(seconds: 5));
      expect(engine.openWebSockets, 0);
      expect(
        log.records.where((r) => r.message.contains('did not read')),
        hasLength(1),
      );
      // Past the drain's moment (3 s + 5 s): nothing more happens.
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(
        log.records.where((r) => r.message.contains('WebSocket closed')),
        hasLength(1),
      );
      client.socket.destroy();
    }, timeout: const Timeout(Duration(seconds: 40)));
  });
}
