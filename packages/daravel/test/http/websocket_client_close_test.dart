import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/raw_ws_client.dart';

/// A client that closes the connection itself gets the server's CLOSE
/// before the connection ends, whether its CLOSE and its FIN come in one
/// write or apart, whether the handler reads, pauses or has cancelled its
/// subscription.
void main() {
  late Application app;
  late ServerEngine engine;
  late MemoryHandler log;

  /// What each handler saw: its messages, then `done:<closeCode>`.
  final seen = <String, List<String>>{};

  /// A handler shaped like the starter's echo demo: reads with `await for`,
  /// closes with 1000 when the loop ends.
  Future<void> demo(WebSocket socket, Request request) async {
    final into = seen[request.uri.queryParameters['id'] ?? ''] = [];
    try {
      await for (final message in socket) {
        into.add(message is String ? message : 'bytes');
        socket.add('Echo: $message');
      }
    } on Object catch (_) {
      into.add('error');
    } finally {
      into.add('done:${socket.closeCode}');
      try {
        await socket.close(WebSocketStatus.normalClosure);
      } on Object catch (_) {}
    }
  }

  setUp(() async {
    seen.clear();
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) => router
            ..ws('/demo', demo, compress: false)
            ..ws('/demo-z', demo, compress: true)
            ..ws('/cancel', (socket, request) async {
              // Cancels its subscription at the first message, without
              // closing the socket.
              final into = seen[request.uri.queryParameters['id']!] = [];
              late final StreamSubscription<dynamic> sub;
              sub = socket.listen((message) {
                into.add(message as String);
                unawaited(sub.cancel());
              });
              await socket.done;
              into.add('done:${socket.closeCode}');
            }, compress: false)
            ..ws('/pause-read', (socket, request) async {
              // Pauses for `ms` at the first message, then reads on.
              final into = seen[request.uri.queryParameters['id']!] = [];
              final ms = int.parse(request.uri.queryParameters['ms']!);
              final done = Completer<void>();
              late final StreamSubscription<dynamic> sub;
              sub = socket.listen((message) {
                into.add(message as String);
                if (into.length == 1) {
                  sub.pause(Future<void>.delayed(Duration(milliseconds: ms)));
                }
              }, onDone: done.complete);
              await done.future;
              await sub.cancel();
              into.add('done:${socket.closeCode}');
            }, compress: false)
            ..ws('/pause-cancel', (socket, request) async {
              // Pauses at the first message, then cancels `ms` later
              // without closing the socket.
              final into = seen[request.uri.queryParameters['id']!] = [];
              final ms = int.parse(request.uri.queryParameters['ms']!);
              late final StreamSubscription<dynamic> sub;
              sub = socket.listen((message) {
                into.add(message as String);
                sub.pause();
                unawaited(
                  Future<void>.delayed(Duration(milliseconds: ms))
                      .then((_) => sub.cancel()),
                );
              });
              await socket.done;
              into.add('done:${socket.closeCode}');
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
  );

  Future<void> sessionsEnd() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (engine.openWebSockets > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(engine.openWebSockets, 0, reason: 'every session ended');
  }

  /// Waits until the server ended the connection (or [limit] passed).
  Future<void> ended(RawWsClient client, [Duration? limit]) async {
    final deadline = DateTime.now().add(limit ?? const Duration(seconds: 5));
    while (!client.ended && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
  }

  final close1000 = RawWsClient.frame(0x8, const [0x03, 0xE8]);

  for (final compress in [false, true]) {
    final route = compress ? '/demo-z' : '/demo';
    final label = compress ? 'compression on' : 'compression off';

    // Repeated: how often the CLOSE and the FIN arrive together depends on
    // the system, so on some systems this only guards against a regression.
    test('$label: CLOSE(1000) and FIN in one write, 200 times: each gets '
        'CLOSE(1000) back before the connection ends', () async {
      var answered = 0;
      final codes = <String>{};
      for (var i = 0; i < 200; i++) {
        final client = await RawWsClient.connect(
          engine.port!,
          '$route?id=f$i',
          deflate: compress,
        );
        client.socket.add(close1000);
        await client.socket.close();
        await ended(client);
        if (await client.closeFrame() == 1000) {
          answered++;
        }
        client.socket.destroy();
        codes.add(seen['f$i']?.last ?? 'none');
      }
      expect(answered, 200);
      await sessionsEnd();
      expect(codes, {'done:1000'});
      expectNoErrors();
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('$label: CLOSE(1000), a pause, then FIN: CLOSE(1000) back', () async {
      for (var i = 0; i < 20; i++) {
        final client = await RawWsClient.connect(
          engine.port!,
          '$route?id=p$i',
          deflate: compress,
        );
        client.socket.add(close1000);
        await client.socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 30));
        await client.socket.close();
        await ended(client);
        expect(await client.closeFrame(), 1000);
        client.socket.destroy();
      }
      await sessionsEnd();
      expect(
        [for (var i = 0; i < 20; i++) seen['p$i']!.last],
        [for (var i = 0; i < 20; i++) 'done:1000'],
      );
      expectNoErrors();
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('$label: FIN without CLOSE: the session ends with 1006', () async {
      final client = await RawWsClient.connect(
        engine.port!,
        '$route?id=fin',
        deflate: compress,
      );
      client.sendWhole(0x1, utf8.encode('hi'));
      while (seen['fin'] == null || seen['fin']!.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      await client.socket.close();
      await sessionsEnd();
      expect(seen['fin'], ['hi', 'done:1006']);
      client.socket.destroy();
      expectNoErrors();
    });

    test('$label: the CLOSE split across two writes (inside its header, and '
        'between its header and its payload): CLOSE(1000) back', () async {
      for (var i = 0; i < 20; i++) {
        final client = await RawWsClient.connect(
          engine.port!,
          '$route?id=s$i',
          deflate: compress,
        );
        // Its header is 6 bytes (2, then the mask).
        final cut = i.isEven ? 3 : 6;
        client.socket.add(close1000.sublist(0, cut));
        await client.socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        client.socket.add(close1000.sublist(cut));
        await client.socket.close();
        await ended(client);
        expect(await client.closeFrame(), 1000);
        client.socket.destroy();
      }
      await sessionsEnd();
      expectNoErrors();
    }, timeout: const Timeout(Duration(minutes: 1)));
  }

  group('a handler that cancelled its subscription and keeps the socket', () {
    test('CLOSE(1000) and FIN in one write, 50 times: CLOSE(1000) back, and '
        'the connection ends soon after it', () async {
      final waits = <int>[];
      for (var i = 0; i < 50; i++) {
        final client = await RawWsClient.connect(
          engine.port!,
          '/cancel?id=c$i',
        );
        client.send(0x1, utf8.encode('first'));
        while (seen['c$i'] == null || seen['c$i']!.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 2));
        }
        // The cancel runs right after the first message.
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final watch = Stopwatch()..start();
        client.socket.add(close1000);
        await client.socket.close();
        await ended(client);
        waits.add(watch.elapsedMilliseconds);
        expect(client.ended, isTrue);
        expect(await client.closeFrame(), 1000, reason: 'session $i');
        client.socket.destroy();
      }
      await sessionsEnd();
      expect([
        for (var i = 0; i < 50; i++) seen['c$i'],
      ], everyElement(['first', 'done:1000']));
      waits.sort();
      // Not the grace (1 s) that bounds a client that does not read.
      expect(waits.last, lessThan(500), reason: 'waits: $waits');
      expectNoErrors();
    }, timeout: const Timeout(Duration(minutes: 1)));

    test('a client that does not read the answer: the connection ends '
        'within the grace', () async {
      final client = await RawWsClient.connect(engine.port!, '/cancel?id=nr');
      client.send(0x1, utf8.encode('first'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      client.pauseReading();
      final watch = Stopwatch()..start();
      client.socket.add(close1000);
      await client.socket.close();
      await sessionsEnd();
      final ms = watch.elapsedMilliseconds;
      // The grace is 1 s; its timer and the session's end take a moment.
      expect(ms, lessThan(2000), reason: '$ms ms');
      expect(seen['nr'], ['first', 'done:1000']);
      client.socket.destroy();
      expectNoErrors();
    });

    test('what the client sends after the cancel is still dropped, and its '
        'CLOSE then ends the session with an answer', () async {
      final client = await RawWsClient.connect(engine.port!, '/cancel?id=fl');
      client.send(0x1, utf8.encode('first'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      for (var i = 0; i < 1024; i++) {
        client.send(0x2, Uint8List(1024));
        if (i % 128 == 127) {
          await client.socket.flush();
        }
      }
      await client.socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(engine.openWebSockets, 1, reason: 'still open');
      client.socket.add(close1000);
      await client.socket.close();
      await ended(client);
      expect(await client.closeFrame(), 1000);
      await sessionsEnd();
      expect(seen['fl'], ['first', 'done:1000']);
      client.socket.destroy();
      expectNoErrors();
    });
  });

  test('a text message that is not UTF-8: the server closes with 1007, and '
      "the client's answer and FIN end the session", () async {
    for (final fin in [true, false]) {
      final id = 'u-$fin';
      final client = await RawWsClient.connect(engine.port!, '/demo?id=$id');
      client.send(0x1, const [0xC3, 0x28]);
      expect(await client.closeFrame(), 1007, reason: 'FIN: $fin');
      final watch = Stopwatch()..start();
      client.send(0x8, const [0x03, 0xEF]);
      if (fin) {
        await client.socket.close();
      } else {
        await client.socket.flush();
      }
      await ended(client);
      final ms = watch.elapsedMilliseconds;
      expect(client.ended, isTrue, reason: 'FIN: $fin');
      // Its answer ends the connection, not the 1 s grace.
      expect(ms, lessThan(500), reason: 'FIN: $fin, $ms ms');
      await sessionsEnd();
      expect(seen[id], ['done:1007'], reason: 'FIN: $fin');
      client.socket.destroy();
    }
    expectNoErrors();
  });

  group('a CLOSE that waits while the handler pauses', () {
    test('the handler reads on after its pause: the CLOSE reaches it, and '
        'the client gets CLOSE(1000) back', () async {
      for (final fin in [true, false]) {
        final id = 'pr-$fin';
        final client = await RawWsClient.connect(
          engine.port!,
          '/pause-read?id=$id&ms=400',
        );
        client.send(0x1, utf8.encode('first'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
        client.socket.add(close1000);
        if (fin) {
          await client.socket.close();
        } else {
          await client.socket.flush();
        }
        await ended(client);
        expect(await client.closeFrame(), 1000, reason: 'FIN: $fin');
        await sessionsEnd();
        expect(seen[id], ['first', 'done:1000'], reason: 'FIN: $fin');
        client.socket.destroy();
      }
      expectNoErrors();
    });

    test('the handler cancels while the CLOSE waits: the session ends with '
        "the client's code, and the client gets its code back", () async {
      for (final fin in [true, false]) {
        final id = 'pc-$fin';
        final client = await RawWsClient.connect(
          engine.port!,
          '/pause-cancel?id=$id&ms=400',
        );
        client.send(0x1, utf8.encode('first'));
        await Future<void>.delayed(const Duration(milliseconds: 150));
        client.send(0x8, const [0x0F, 0xA0]);
        if (fin) {
          await client.socket.close();
        } else {
          await client.socket.flush();
        }
        await ended(client);
        expect(await client.closeFrame(), 4000, reason: 'FIN: $fin');
        await sessionsEnd();
        expect(seen[id], ['first', 'done:4000'], reason: 'FIN: $fin');
        client.socket.destroy();
      }
      expectNoErrors();
    });
  });
}
