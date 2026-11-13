@Tags(['security'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/raw_ws_client.dart';

/// The WebSocket guard (http/websocket_guard.dart) through a real socket,
/// with a raw client that writes frames by hand.
void main() {
  late Application app;
  late ServerEngine engine;
  late MemoryHandler log;
  final received = <Object>[];
  final ended = <Completer<void>>[];

  Future<void> echo(WebSocket socket, Request _) {
    final done = Completer<void>();
    ended.add(done);
    socket.listen((message) {
      received.add(message as Object);
      socket.add(message);
    }, onDone: done.complete);
    return done.future;
  }

  setUp(() async {
    received.clear();
    ended.clear();
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) {
            router
              ..ws('/echo', echo, compress: false, maxPayloadBytes: 65536)
              // The default limit (1 MiB).
              ..ws('/default', echo, compress: false)
              ..ws('/deflate', echo, maxPayloadBytes: 65536)
              // Many pings between fragments (the differential test).
              ..ws(
                '/diff',
                echo,
                compress: false,
                maxPayloadBytes: 65536,
                controlFrameBurst: 100000,
              )
              ..ws(
                '/diff-deflate',
                echo,
                maxPayloadBytes: 65536,
                controlFrameBurst: 100000,
              )
              ..ws(
                '/quick',
                echo,
                compress: false,
                maxPayloadBytes: 65536,
                assembleTimeout: const Duration(milliseconds: 300),
              )
              // Sends 2 MB at once, then closes: close waits for it all.
              ..ws('/burst', (socket, _) async {
                socket.add(Uint8List(2 << 20));
                await socket.close(1000);
              }, compress: false)
              // The server pings the client every 200 ms.
              ..ws('/pinging', (socket, request) {
                socket.pingInterval = const Duration(milliseconds: 200);
                return echo(socket, request);
              }, compress: false)
              // Each "go <n> <seed>" streams n messages of random sizes
              // back, while the client pings in between.
              ..ws(
                '/stream',
                (socket, _) {
                  final done = Completer<void>();
                  socket.listen((message) {
                    final parts = (message as String).split(' ');
                    final random = Random(int.parse(parts[2]));
                    for (var i = 0; i < int.parse(parts[1]); i++) {
                      socket.add(Uint8List(random.nextInt(200000)));
                    }
                  }, onDone: done.complete);
                  return done.future;
                },
                compress: false,
                maxBufferedBytes: 64 << 20,
                controlFrameBurst: 100000,
              );
          },
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

  Future<RawWsClient> connect(String path, {bool deflate = false}) =>
      RawWsClient.connect(engine.port!, path, deflate: deflate);

  final aaaa = utf8.encode('AAAA');
  final bbbb = utf8.encode('BBBB');

  test('unfragmented messages of every length pass as they arrived (a '
      'payload at any offset in its buffer)', () async {
    final client = await connect('/diff');
    for (final size in [0, 10, 15, 16, 125, 126, 300, 65535]) {
      client.send(0x2, List.generate(size, (i) => i & 0xFF));
      final message = await client.nextMessage();
      expect(message.payload, List.generate(size, (i) => i & 0xFF));
    }
    expect(received, hasLength(8));
    await client.close();
  });

  group('fragmented messages', () {
    test('a ping between fragments: the message stays whole, the pong '
        'carries the ping', () async {
      final client = await connect('/echo');
      client
        ..send(0x1, aaaa, fin: false)
        ..send(0x9, utf8.encode('PP'))
        ..send(0x0, bbbb);
      final pong = await client.next();
      expect(pong.opcode, 0xA);
      expect(utf8.decode(pong.payload), 'PP');
      final message = await client.next();
      expect(message.opcode, 0x1);
      expect(utf8.decode(message.payload), 'AAAABBBB');
      expect(received, ['AAAABBBB']);
      await client.close();
    });

    test('a legal fragmented message below the limit arrives whole, also '
        'compressed', () async {
      for (final deflate in [false, true]) {
        received.clear();
        final client = await connect(
          deflate ? '/deflate' : '/echo',
          deflate: deflate,
        );
        final text = List.generate(40000, (i) => 'abc'[i % 3]).join();
        client.sendFragmented(0x1, utf8.encode(text), pieces: 7);
        final message = await client.nextMessage();
        printOnFailure(
          'server log: ${[for (final r in log.records) r.message]}; '
          'frame ${message.opcode}, ${message.payload.length} bytes',
        );
        expect(utf8.decode(message.payload), text, reason: 'deflate $deflate');
        expect(received, [text]);
        await client.close();
      }
    });

    test('fragments without end are closed at the limit (1009); the memory '
        'is measured in websocket_guard_memory_test.dart', () async {
      final client = await connect('/echo');
      final piece = Uint8List(8192);
      client.send(0x1, piece, fin: false);
      for (var i = 0; i < 2000 && !client.ended; i++) {
        client.send(0x0, piece, fin: false);
        if (i % 50 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
      final close = await client.closeFrame();
      expect(close, 1009);
      expect(received, isEmpty);
    });

    test('a fragmented message completed above the limit never reaches the '
        'handler', () async {
      final client = await connect('/echo');
      client
        ..send(0x1, Uint8List(40000), fin: false)
        ..send(0x0, Uint8List(40000));
      expect(await client.closeFrame(), 1009);
      expect(received, isEmpty);
    });

    test('after a violation, what the client still sends is dropped: no '
        'echo, no PONG', () async {
      final client = await connect('/echo');
      client
        ..send(0x1, Uint8List(40000), fin: false)
        ..send(0x0, Uint8List(40000))
        // Sent before the client saw the close.
        ..send(0x1, utf8.encode('after'))
        ..send(0x9, utf8.encode('ping'));
      final opcodes = <int>[];
      while (opcodes.lastOrNull != 0x8) {
        opcodes.add((await client.next()).opcode);
      }
      expect(opcodes, [0x8]);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, isEmpty);
    });

    test('a close in the middle of a message drops the message', () async {
      final client = await connect('/echo');
      client
        ..send(0x1, aaaa, fin: false)
        ..send(0x8, [0x03, 0xE8]);
      expect(await client.closeFrame(), 1000);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(received, isEmpty);
    });

    test('a message that does not complete in time is closed (1008): '
        'fragments, and a single frame whose payload trickles', () async {
      final fragmented = await connect('/quick');
      fragmented.send(0x1, aaaa, fin: false);
      expect(await fragmented.closeFrame(), 1008);

      final trickled = await connect('/quick');
      // A header announcing 1 000 bytes, then 10 of them.
      trickled.socket.add(RawWsClient.header(0x1, 1000, fin: true));
      trickled.socket.add(Uint8List(10));
      expect(await trickled.closeFrame(), 1008);
      expect(received, isEmpty);
    });
  });

  group('control frames', () {
    test(
      'a client that pings faster than the limit is closed (1008)',
      () async {
        final client = await connect('/echo');
        for (var i = 0; i < 100; i++) {
          client.send(0x9, utf8.encode('$i'));
        }
        var pongs = 0;
        while (true) {
          final frame = await client.next();
          if (frame.opcode == 0xA) {
            pongs++;
            continue;
          }
          expect(frame.opcode, 0x8);
          expect(frame.closeCode, 1008);
          break;
        }
        // The burst of 20, and what refilled meanwhile.
        expect(pongs, lessThanOrEqualTo(21));
      },
    );
  });

  group('what the server writes', () {
    test('the same frames in the same order as a server without the guard, '
        'for pings and messages mixed', () async {
      final plain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      plain.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(
          request,
          compression: CompressionOptions.compressionOff,
        );
        socket.listen(socket.add, onDone: socket.close);
      });
      addTearDown(() => plain.close(force: true));
      Future<List<String>> run(int port, String path) async {
        final client = await RawWsClient.connect(port, path);
        final seen = <String>[];
        for (var i = 0; i < 15; i++) {
          client
            ..send(0x9, utf8.encode('p$i'))
            ..send(0x1, utf8.encode('m$i' * (i * 700)));
          for (var k = 0; k < 2; k++) {
            final frame = await client.next();
            seen.add('${frame.opcode}:${utf8.decode(frame.payload)}');
          }
        }
        await client.close();
        return seen;
      }

      final guarded = await run(engine.port!, '/echo');
      final alone = await run(plain.port, '/');
      expect(guarded, alone);
      expect(guarded, hasLength(30));
    });

    test('close() waits for what is queued: a client that reads late gets '
        'all of it, then the close frame', () async {
      final client = await connect('/burst');
      client.pauseReading();
      await Future<void>.delayed(const Duration(milliseconds: 400));
      client.resumeReading();
      var bytes = 0;
      while (true) {
        final frame = await client.next();
        if (frame.opcode == 0x8) {
          expect(frame.closeCode, 1000);
          break;
        }
        bytes += frame.payload.length;
      }
      expect(bytes, 2 << 20);
    });

    test('pingInterval still works: its pings reach the client, '
        "the client's pongs reach it, and silence closes (1001)", () async {
      final client = await connect('/pinging');
      // Answer three pings.
      for (var answered = 0; answered < 3;) {
        final frame = await client.next();
        if (frame.opcode == 0x9) {
          client.send(0xA, frame.payload);
          answered++;
        }
      }
      // Then stop answering: closed going away.
      while (true) {
        final frame = await client.next();
        if (frame.opcode == 0x8) {
          expect(frame.closeCode, 1001);
          break;
        }
      }
    });

    test('a pong never lands inside a frame: messages of random sizes '
        'stream out while pings come in at random moments', () async {
      final random = Random(20261113);
      final client = await connect('/stream');
      const count = 60;
      client.send(0x1, utf8.encode('go $count 7'));
      var pings = 0;
      for (var i = 0; i < 40; i++) {
        client.send(0x9, utf8.encode('$i'));
        pings++;
        await Future<void>.delayed(Duration(milliseconds: random.nextInt(8)));
      }
      final expected = Random(7);
      var messages = 0;
      var pongs = 0;
      while (messages < count || pongs < pings) {
        final frame = await client.next();
        if (frame.opcode == 0xA) {
          pongs++;
        } else {
          expect(frame.opcode, 0x2, reason: 'frame ${messages + pongs}');
          expect(frame.payload.length, expected.nextInt(200000));
          messages++;
        }
      }
      expect((messages, pongs), (count, pings));
      await client.close();
    });
  });

  test('differential: random messages, fragmented at random with pings in '
      'between, arrive as the same messages unfragmented give', () async {
    final random = Random(20261113);
    var cases = 0;
    for (final deflate in [false, true]) {
      // The reference: each message as one frame.
      final messages = <(int, Uint8List)>[
        for (var i = 0; i < 60; i++)
          (
            random.nextBool() ? 0x1 : 0x2,
            Uint8List.fromList(
              List.generate(
                random.nextInt(4) == 0
                    ? random.nextInt(65536)
                    : random.nextInt(300),
                (_) => 0x20 + random.nextInt(0x5E),
              ),
            ),
          ),
      ];
      Future<List<Object>> run({required bool fragmented}) async {
        received.clear();
        final client = await connect(
          deflate ? '/diff-deflate' : '/diff',
          deflate: deflate,
        );
        for (final (opcode, payload) in messages) {
          if (fragmented) {
            client.sendFragmented(
              opcode,
              payload,
              pieces: 1 + random.nextInt(6),
              random: random,
            );
          } else {
            client.sendWhole(opcode, payload);
          }
        }
        final deadline = DateTime.now().add(const Duration(seconds: 20));
        while (received.length < messages.length &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        printOnFailure(
          'fragmented $fragmented, deflate $deflate: ${received.length} of '
          '${messages.length}; server log: '
          '${[for (final r in log.records) r.message]}',
        );
        await client.close();
        return [
          for (final m in received)
            m is String ? m : List<int>.from(m as List<int>),
        ];
      }

      final whole = await run(fragmented: false);
      final pieces = await run(fragmented: true);
      expect(whole, hasLength(messages.length));
      expect(pieces, whole, reason: 'deflate $deflate');
      cases += messages.length;
    }
    expect(cases, 120);
  });

  test('messages arrive the same wherever the TCP chunks are cut: '
      'headers split across chunks, many frames in one chunk', () async {
    final random = Random(1113);
    final messages = <String>[
      for (var i = 0; i < 40; i++)
        String.fromCharCodes(
          List.generate(
            random.nextInt(3) == 0
                ? 126 + random.nextInt(400)
                : random.nextInt(40),
            (_) => 0x61 + random.nextInt(26),
          ),
        ),
    ];
    final stream = BytesBuilder();
    for (final message in messages) {
      final bytes = utf8.encode(message);
      if (bytes.length < 2 || random.nextBool()) {
        stream.add(RawWsClient.frame(0x1, bytes));
        continue;
      }
      final cut = 1 + random.nextInt(bytes.length - 1);
      stream
        ..add(RawWsClient.frame(0x1, bytes.sublist(0, cut), fin: false))
        ..add(RawWsClient.frame(0x9, utf8.encode('p')))
        ..add(RawWsClient.frame(0x0, bytes.sublist(cut)));
    }
    final bytes = stream.takeBytes();
    final client = await connect('/diff');
    client.socket.setOption(SocketOption.tcpNoDelay, true);
    for (var at = 0; at < bytes.length;) {
      final end = min(bytes.length, at + 1 + random.nextInt(24));
      client.socket.add(bytes.sublist(at, end));
      await client.socket.flush();
      await Future<void>.delayed(const Duration(milliseconds: 1));
      at = end;
    }
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (received.length < messages.length &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(received, messages);
    await client.close();
  });

  test('the permessage-deflate answer is the same as a server gives '
      'without the guard', () async {
    final plain = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    plain.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(
        request,
        compression: CompressionOptions.compressionDefault,
      );
      await socket.close();
    });
    addTearDown(() => plain.close(force: true));
    final viaGuard = await RawWsClient.handshake(
      engine.port!,
      '/deflate',
      deflate: true,
    );
    final viaPlain = await RawWsClient.handshake(
      plain.port,
      '/',
      deflate: true,
    );
    expect(
      viaGuard['sec-websocket-extensions'],
      viaPlain['sec-websocket-extensions'],
    );
    expect(
      viaGuard['sec-websocket-extensions'],
      contains('permessage-deflate'),
    );
    expect(viaGuard['sec-websocket-accept'], viaPlain['sec-websocket-accept']);
  });

  group('frame lengths that do not fit', () {
    const huge = [0x7FFFFFFFFFFFFFFF, 0x7FFFFFFFFFFFFFF5];

    /// Whether the server answered with [code] within a second, holding
    /// nothing for the handler.
    Future<void> expectClosed(RawWsClient client, int code) async {
      final watch = Stopwatch()..start();
      expect(await client.closeFrame(), code);
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(received, isEmpty);
      expect(
        log.records.where((r) => r.level.index >= LogLevel.error.index),
        isEmpty,
        reason: 'nothing failed inside the server',
      );
    }

    for (final path in ['/echo', '/default']) {
      for (final length in huge) {
        test('a continuation frame of length 0x${length.toRadixString(16)} '
            'after 100 bytes is closed with 1009 at once ($path)', () async {
          final client = await connect(path);
          client
            ..send(0x1, Uint8List(100), fin: false)
            ..socket.add(RawWsClient.header(0x0, length, fin: false))
            ..socket.add(Uint8List(4096));
          await expectClosed(client, 1009);
        });
      }
    }

    test('a 64-bit length with the top bit set is closed with 1002: on a '
        'continuation frame and on a first frame', () async {
      final topBit = [0xFF, 0, 0, 0, 0, 0, 0, 0];
      final continuation = await connect('/echo');
      continuation
        ..send(0x1, Uint8List(100), fin: false)
        ..socket.add([0x00, 0x80 | 127, ...topBit, 0, 0, 0, 0]);
      await expectClosed(continuation, 1002);
      final first = await connect('/echo');
      first.socket.add([0x81, 0x80 | 127, ...topBit, 0, 0, 0, 0]);
      await expectClosed(first, 1002);
    });

    test(
      'a PING with an RSV bit set is closed with 1002, not answered',
      () async {
        for (final rsv in [0x40, 0x20, 0x10]) {
          final client = await connect('/echo');
          client.socket.add(
            RawWsClient.frame(0x9, utf8.encode('p'))..[0] |= rsv,
          );
          final first = await client.next();
          expect(first.opcode, 0x8, reason: 'no PONG first');
          expect(first.closeCode, 1002);
        }
      },
    );

    test('random frame lengths, near 2^63 - 1 and near the limit: the '
        'server holds no more than the limit and closes as a model of the '
        'limit says', () async {
      const limit = 65536;
      final random = Random(20261113);
      int pick() => switch (random.nextInt(6)) {
        0 => 0x7FFFFFFFFFFFFFFF - random.nextInt(64),
        1 => limit - random.nextInt(64),
        2 => limit + random.nextInt(64),
        3 => random.nextInt(limit ~/ 4),
        4 => (limit ~/ 2) + random.nextInt(64),
        _ => random.nextInt(200),
      };
      for (var round = 0; round < 40; round++) {
        received.clear();
        final lengths = [
          for (var i = 0; i < 2 + random.nextInt(4); i++) pick(),
        ];
        // The model: the first frame whose running total passes the limit
        // closes the connection with 1009; if none does, the message
        // arrives whole.
        var total = 0;
        int? closesAt;
        for (var i = 0; i < lengths.length; i++) {
          if (lengths[i] > limit - total) {
            closesAt = i;
            break;
          }
          total += lengths[i];
        }
        final client = await connect('/echo');
        for (var i = 0; i < lengths.length; i++) {
          final last = i == lengths.length - 1;
          final opcode = i == 0 ? 0x2 : 0x0;
          if (closesAt != null && i == closesAt) {
            // Its header and a little of its payload: the server must
            // close on the header alone.
            client
              ..socket.add(RawWsClient.header(opcode, lengths[i], fin: last))
              ..socket.add(Uint8List(1024));
            break;
          }
          client
            ..socket.add(RawWsClient.header(opcode, lengths[i], fin: last))
            ..socket.add(Uint8List(lengths[i]));
        }
        printOnFailure('round $round: lengths $lengths, closes at $closesAt');
        if (closesAt != null) {
          expect(await client.closeFrame(), 1009);
          expect(received, isEmpty);
        } else {
          final message = await client.nextMessage();
          expect(message.payload.length, total);
          await client.close();
        }
      }
      expect(
        log.records.where((r) => r.level.index >= LogLevel.error.index),
        isEmpty,
        reason: 'no assertion or error inside the server',
      );
    });
  });

  test("a session closed for a violation ends with the guard's grace, also "
      'when the client neither answers the close nor goes away', () async {
    final client = await connect('/echo');
    client
      ..send(0x1, Uint8List(40000), fin: false)
      ..send(0x0, Uint8List(40000));
    expect(await client.closeFrame(), 1009);
    // The client stays connected and silent.
    final watch = Stopwatch()..start();
    while (engine.openWebSockets > 0 &&
        watch.elapsed < const Duration(seconds: 10)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    printOnFailure('ended after ${watch.elapsedMilliseconds} ms');
    expect(engine.openWebSockets, 0);
    // The guard's grace is 1 s; the session ends with it.
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 2500)));
  });
}
