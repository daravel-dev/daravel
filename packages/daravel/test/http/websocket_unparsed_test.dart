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

/// Once what the server holds for a handler that does not read is over its
/// limit, the guard stops reading the chunk it is in, not only TCP: the
/// rest of that chunk waits unparsed, is parsed first (in order) once the
/// handler reads, and is given up on every way a session ends.
void main() {
  tearDown(expectWebSocketCountsReleased);

  late Application app;
  late ServerEngine engine;
  late MemoryHandler log;

  /// What each handler saw: its messages, then `done:<closeCode>`.
  final seen = <String, List<String>>{};

  setUp(() async {
    seen.clear();
    WebSocketGuardStats.reset();
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) => router
            ..ws('/later-read', (socket, request) async {
              // Listens after `delay` ms, then pauses and resumes inside
              // its onData, now and then for a millisecond.
              final into = seen[request.uri.queryParameters['id']!] = [];
              await Future<void>.delayed(
                Duration(
                  milliseconds: int.parse(
                    request.uri.queryParameters['delay']!,
                  ),
                ),
              );
              final done = Completer<void>();
              var count = 0;
              late final StreamSubscription<dynamic> reading;
              reading = socket.listen((message) {
                into.add((message as String).split(':').first);
                count++;
                reading
                  ..pause()
                  ..resume();
                if (count % 7 == 0) {
                  reading.pause(
                    Future<void>.delayed(const Duration(milliseconds: 1)),
                  );
                }
              }, onDone: done.complete);
              await done.future;
              await reading.cancel();
              into.add('done:${socket.closeCode}');
            }, compress: false)
            ..ws('/never', (socket, request) async {
              final into = seen[request.uri.queryParameters['id']!] = [];
              await socket.done;
              into.add('done:${socket.closeCode}');
            }, compress: false)
            ..ws('/later-cancel', (socket, request) async {
              // Listens after `delay` ms and cancels at the first message.
              final into = seen[request.uri.queryParameters['id']!] = [];
              await Future<void>.delayed(
                Duration(
                  milliseconds: int.parse(
                    request.uri.queryParameters['delay']!,
                  ),
                ),
              );
              late final StreamSubscription<dynamic> reading;
              reading = socket.listen((message) {
                into.add((message as String).split(':').first);
                unawaited(reading.cancel());
              });
              await socket.done;
              into.add('done:${socket.closeCode}');
            }, compress: false)
            ..ws('/later-close', (socket, request) async {
              // Never listens; closes with 4001 after `delay` ms.
              final into = seen[request.uri.queryParameters['id']!] = [];
              await Future<void>.delayed(
                Duration(
                  milliseconds: int.parse(
                    request.uri.queryParameters['delay']!,
                  ),
                ),
              );
              await socket.close(4001);
              into.add('done:${socket.closeCode}');
            }, compress: false)
            ..ws(
              '/flood',
              (socket, request) async {
                // Never listens; writes after `delay` ms until the client,
                // which does not read, counts as slow.
                await Future<void>.delayed(
                  Duration(
                    milliseconds: int.parse(
                      request.uri.queryParameters['delay']!,
                    ),
                  ),
                );
                while (socket.readyState == WebSocket.open) {
                  socket.add(Uint8List(64 << 10));
                  await Future<void>.delayed(Duration.zero);
                }
              },
              compress: false,
              maxBufferedBytes: 1 << 20,
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

  int count(String name) => WebSocketGuardStats.toJson()[name]!;

  /// [messages] text messages `<index>:` padded to 24 KiB, each in three
  /// fragments, in one buffer: their hand-ons fall inside a chunk, so the
  /// limit is passed there and the rest of the chunk is left unparsed.
  Uint8List numbered(int messages, {int from = 0}) {
    final all = BytesBuilder(copy: false);
    for (var i = from; i < from + messages; i++) {
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

  /// Waits until [condition] holds, at most [within].
  Future<void> until(
    bool Function() condition, {
    Duration within = const Duration(seconds: 10),
  }) async {
    final deadline = DateTime.now().add(within);
    while (!condition() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  Future<void> sessionsEnd() async {
    await until(() => engine.openWebSockets == 0);
    expect(engine.openWebSockets, 0, reason: 'the session ended');
  }

  /// A connection to [path] that sends [bytes] at once, and the moment the
  /// server holds the rest of a chunk unparsed.
  Future<RawWsClient> withUnparsed(String path, Uint8List bytes) async {
    final client = await RawWsClient.connect(engine.port!, path);
    client.socket.add(bytes);
    await until(() => count('unparsed') > 0);
    expect(count('unparsed'), greaterThan(0), reason: 'a chunk waits');
    return client;
  }

  test('a handler that reads late and pauses and resumes inside its onData '
      'gets 300 messages complete and in order', () async {
    final client = await RawWsClient.connect(
      engine.port!,
      '/later-read?id=order&delay=500',
    );
    client.socket.add(numbered(300));
    await until(() => (seen['order']?.length ?? 0) >= 300);
    expect(count('unparsedPeak'), greaterThan(0), reason: 'a chunk waited');
    client.send(0x8, const [0x03, 0xE8]);
    await sessionsEnd();
    expect(seen['order'], [for (var i = 0; i < 300; i++) '$i', 'done:1000']);
    client.socket.destroy();
  }, timeout: const Timeout(Duration(seconds: 60)));

  group('what is left of a chunk is given up when the session ends', () {
    test('the unread wait ends it (1008)', () async {
      final client = await withUnparsed('/never?id=w', numbered(40));
      expect(await client.closeFrame(), 1008);
      expect(count('unparsed'), 0, reason: 'given up with the close');
      await sessionsEnd();
      expect(seen['w'], ['done:1008']);
      expect(count('unparsed'), 0);
      client.socket.destroy();
    });

    test('a frame the protocol refuses in it, once read (1002)', () async {
      final bytes = BytesBuilder(copy: false)
        ..add(numbered(40))
        // An unmasked frame.
        ..add(const [0x81, 0x02, 0x68, 0x69]);
      final client = await withUnparsed(
        '/later-read?id=v&delay=500',
        bytes.takeBytes(),
      );
      expect(await client.closeFrame(), 1002);
      expect(count('unparsed'), 0, reason: 'given up with the close');
      await sessionsEnd();
      expect(seen['v']!.last, 'done:1002');
      expect(count('unparsed'), 0);
      client.socket.destroy();
    });

    test('the handler cancels its subscription: the rest is read and '
        'dropped, and a CLOSE in it ends the session with its code', () async {
      final bytes = BytesBuilder(copy: false)
        ..add(numbered(40))
        ..add(RawWsClient.frame(0x8, const [0x0F, 0xA0]))
        ..add(numbered(10, from: 40));
      final client = await withUnparsed(
        '/later-cancel?id=c&delay=500',
        bytes.takeBytes(),
      );
      expect(await client.closeFrame(), 4000);
      expect(count('unparsed'), 0, reason: 'read and dropped by then');
      await sessionsEnd();
      expect(seen['c'], ['0', 'done:4000']);
      expect(count('unparsed'), 0);
      client.socket.destroy();
    });

    test('the handler closes the socket', () async {
      final client = await withUnparsed(
        '/later-close?id=a&delay=500',
        numbered(40),
      );
      expect(await client.closeFrame(), 4001);
      client.send(0x8, const [0x0F, 0xA1]);
      await sessionsEnd();
      expect(count('unparsed'), 0);
      client.socket.destroy();
    });

    test('the server destroys the socket (a slow client)', () async {
      final client = await withUnparsed('/flood?delay=500', numbered(40));
      client.pauseReading();
      await sessionsEnd();
      expect(
        log.records.where((r) => r.message.contains('read too slowly')),
        isNotEmpty,
      );
      expect(count('unparsed'), 0);
      client.socket.destroy();
    });

    test('the server stops', () async {
      final client = await withUnparsed('/never?id=s', numbered(40));
      await engine.stop();
      expect(engine.openWebSockets, 0);
      expect(count('unparsed'), 0);
      client.socket.destroy();
    });
  });

  test(
    'a CLOSE behind what is left of a chunk is not read while the handler '
    'does not read: the session ends with 1008 after the unread wait',
    () async {
      final bytes = BytesBuilder(copy: false)
        ..add(numbered(40))
        ..add(RawWsClient.frame(0x8, const [0x0F, 0xA0]));
      final watch = Stopwatch()..start();
      final client = await withUnparsed('/never?id=cl', bytes.takeBytes());
      expect(await client.closeFrame(), 1008);
      expect(count('unparsed'), 0, reason: 'given up with the close');
      expect(watch.elapsed, greaterThan(const Duration(seconds: 4)));
      await sessionsEnd();
      expect(seen['cl'], ['done:1008']);
      client.socket.destroy();
    },
  );
}
