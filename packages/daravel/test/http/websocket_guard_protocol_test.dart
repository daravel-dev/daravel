@Tags(['security'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/raw_ws_client.dart';
import 'support/websocket_counts.dart';

/// The guard checks every frame a client sends by RFC 6455 itself, whether
/// the handler reads or not, and answers a CLOSE within the protocol.
void main() {
  // First, so it runs last: after every tear-down of the tests.
  tearDown(expectWebSocketCountsReleased);

  late Application app;
  late ServerEngine engine;

  /// What each handler saw: `done:<closeCode>`, or `threw:<error>`.
  final seen = <String, List<String>>{};

  Future<void> record(
    String id,
    Future<void> Function(List<String> into) body,
  ) async {
    final into = seen[id] = [];
    try {
      await body(into);
    } on Object catch (error) {
      into.add('threw:$error');
    }
  }

  setUp(() async {
    seen.clear();
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) => router
            ..ws('/listen', (socket, request) {
              return record(request.uri.queryParameters['id']!, (into) async {
                await socket.listen((_) {}).asFuture<void>();
                into.add('done:${socket.closeCode}');
              });
            }, compress: false)
            ..ws('/silent', (socket, request) {
              return record(request.uri.queryParameters['id']!, (into) async {
                await socket.done;
                into.add('done:${socket.closeCode}');
              });
            }, compress: false)
            ..ws('/setup', (socket, request) {
              // Async set-up longer than the unread wait, then a listen.
              return record(request.uri.queryParameters['id']!, (into) async {
                await Future<void>.delayed(const Duration(milliseconds: 5500));
                await socket.listen((_) {}).asFuture<void>();
                into.add('done:${socket.closeCode}');
              });
            }, compress: false),
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

  /// A connection whose session has started.
  Future<RawWsClient> open(String path) async {
    final client = await RawWsClient.connect(engine.port!, path);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (engine.openWebSockets == 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(engine.openWebSockets, 1);
    return client;
  }

  Future<bool> sessionEnds(Duration within) async {
    final deadline = DateTime.now().add(within);
    while (engine.openWebSockets > 0 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return engine.openWebSockets == 0;
  }

  Future<List<String>> seenBy(String id) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while ((seen[id]?.isEmpty ?? true) && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return seen[id] ?? const [];
  }

  /// The server's CLOSE frame as it is on the wire.
  Future<WsFrame?> serverClose(RawWsClient client) async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      try {
        final frame = await client.next();
        if (frame.opcode == 0x8) {
          return frame;
        }
      } on TimeoutException {
        return null;
      }
    }
    return null;
  }

  /// One frame as written, mask or not: [rsv] the RSV bits (0x40, 0x20,
  /// 0x10), [length] the declared length when it differs from the
  /// payload's.
  Uint8List raw(
    int opcode,
    List<int> payload, {
    bool fin = true,
    bool masked = true,
    int rsv = 0,
  }) {
    final out = BytesBuilder()..addByte((fin ? 0x80 : 0) | rsv | opcode);
    final length = payload.length;
    final maskBit = masked ? 0x80 : 0;
    if (length < 126) {
      out.addByte(maskBit | length);
    } else {
      out
        ..addByte(maskBit | 126)
        ..addByte(length >> 8)
        ..addByte(length & 0xFF);
    }
    if (masked) {
      const key = [0x12, 0x34, 0x56, 0x78];
      out
        ..add(key)
        ..add([for (var i = 0; i < length; i++) payload[i] ^ key[i & 3]]);
    } else {
      out.add(payload);
    }
    return out.takeBytes();
  }

  Uint8List closePayload(int code, [List<int> reason = const []]) =>
      Uint8List.fromList([code >> 8, code & 0xFF, ...reason]);

  group('every frame is checked, read or not (RFC 6455 §5.2, §5.5)', () {
    final shapes = <String, List<int> Function()>{
      'a CLOSE of 126 bytes': () =>
          raw(0x8, closePayload(1000, [for (var i = 0; i < 124; i++) 0x61])),
      'a fragmented CLOSE': () => raw(0x8, closePayload(1000), fin: false),
      'an unmasked CLOSE': () => raw(0x8, closePayload(1000), masked: false),
      'an unmasked text frame': () =>
          raw(0x1, utf8.encode('hi'), masked: false),
      'a reserved opcode (0x3)': () => raw(0x3, utf8.encode('hi')),
      'a text frame with RSV2': () => raw(0x1, utf8.encode('hi'), rsv: 0x20),
      'a text frame with RSV1, no compression agreed': () =>
          raw(0x1, utf8.encode('hi'), rsv: 0x40),
      'a continuation with no message': () => raw(0x0, utf8.encode('hi')),
      'a CLOSE of one byte': () => raw(0x8, const [0x03]),
      'a PING of 126 bytes': () => raw(0x9, List.filled(126, 0)),
      'RSV1 on a PING': () => raw(0x9, const [1], rsv: 0x40),
      'RSV1 on a continuation': () => [
        ...raw(0x1, utf8.encode('a'), fin: false),
        ...raw(0x0, utf8.encode('b'), rsv: 0x40),
      ],
      'a length of 5 in the 16-bit form': () => [
        0x81, 0x80 | 126, 0, 5, 0, 0, 0, 0, //
        ...utf8.encode('hello'),
      ],
      'a length of 200 in the 64-bit form': () => [
        0x82, 0x80 | 127, 0, 0, 0, 0, 0, 0, 0, 200, 0, 0, 0, 0, //
        ...List.filled(200, 0),
      ],
      'a 64-bit length with the top bit set (2^63)': () => [
        0x82, 0x80 | 127, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, //
      ],
      'an unmasked PING': () => raw(0x9, const [1], masked: false),
    };
    for (final MapEntry(key: name, value: bytes) in shapes.entries) {
      for (final route in ['listen', 'silent']) {
        test('$name on a route that does ${route == 'listen' ? '' : 'not '}'
            'read: 1002, and the session ends', () async {
          final client = await open('/$route?id=a');
          client.socket.add(bytes());
          expect(await client.closeFrame(), 1002);
          expect(
            await sessionEnds(const Duration(seconds: 4)),
            isTrue,
            reason: 'the session must not be held',
          );
          client.socket.destroy();
        });
      }
    }
  });

  group("the client's CLOSE", () {
    for (final route in ['listen', 'silent']) {
      test('a reason that is not UTF-8: 1007, the answer within 125 bytes '
          '($route)', () async {
        final client = await open('/$route?id=c');
        client.socket.add(raw(0x8, closePayload(1000, List.filled(123, 0xFF))));
        final close = await serverClose(client);
        expect(close, isNotNull);
        expect(close!.payload.length, lessThanOrEqualTo(125));
        expect(close.closeCode, 1007);
        client.socket.destroy();
      });

      test('a long UTF-8 reason is answered within 125 bytes, cut at a '
          'character ($route)', () async {
        final client = await open('/$route?id=c2');
        // 41 three-byte characters: 123 bytes, a valid CLOSE.
        final reason = utf8.encode('€' * 41);
        client.socket.add(raw(0x8, closePayload(4001, reason)));
        final close = await serverClose(client);
        expect(close, isNotNull);
        expect(close!.payload.length, lessThanOrEqualTo(125));
        expect(close.closeCode, 4001);
        // Decodes strictly: no character cut in half.
        utf8.decode(close.payload.sublist(2));
        client.socket.destroy();
      });

      for (final code in [0, 999, 1004, 1005, 1006, 1015, 1016, 2999, 5000]) {
        test('code $code is not a code a client may send: 1002, never '
            'reported ($route)', () async {
          final client = await open('/$route?id=d$code');
          client.socket.add(raw(0x8, closePayload(code)));
          expect(await client.closeFrame(), 1002);
          expect(await sessionEnds(const Duration(seconds: 4)), isTrue);
          final done = await seenBy('d$code');
          expect(done, hasLength(1));
          expect(done.single, isNot('done:$code'));
          client.socket.destroy();
        });
      }
    }
  });

  test('a listen after the session ended unread gets the end at once, the '
      "client's code, and never throws", () async {
    final client = await open('/setup?id=e');
    client
      ..send(0x1, utf8.encode('early'))
      ..send(0x8, closePayload(4000));
    expect(await seenBy('e'), ['done:4000']);
    client.socket.destroy();
  }, timeout: const Timeout(Duration(seconds: 30)));

  test("the client's code stands when its CLOSE fills what is held and its "
      'FIN follows', () async {
    final client = await open('/silent?id=f');
    // Held: the frame's 8-byte header and 65 270 bytes, each item counted
    // with its 128 bytes of cost, 65 534 in all; the CLOSE (6 + 2 bytes,
    // one more item) takes it past 64 KiB.
    client
      ..socket.add(raw(0x2, Uint8List(65270)))
      ..socket.add(raw(0x8, closePayload(4000)));
    await client.socket.flush();
    await client.socket.close();
    expect(await seenBy('f'), ['done:4000']);
    client.socket.destroy();
  }, timeout: const Timeout(Duration(seconds: 30)));
}
