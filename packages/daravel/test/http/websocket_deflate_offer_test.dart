import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// On a route with `compress: true`, a client's permessage-deflate offer
/// whose window size is not one RFC 7692 allows (8 to 15) is declined: the
/// connection is agreed to without compression and works.
void main() {
  late Application app;
  late ServerEngine engine;

  setUp(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) => router.ws('/c', (socket, _) {
            socket.listen(socket.add);
          }, compress: true),
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

  /// The handshake's extension answer for [offer], and whether an
  /// uncompressed text frame is echoed afterwards.
  Future<(String?, bool)> handshake(String offer) async {
    final socket = await Socket.connect('127.0.0.1', engine.port!);
    addTearDown(socket.destroy);
    final received = BytesBuilder();
    final upgraded = Completer<String>();
    final echoed = Completer<bool>();
    socket.listen(
      (chunk) {
        received.add(chunk);
        final bytes = received.toBytes();
        final text = latin1.decode(bytes);
        final end = text.indexOf('\r\n\r\n');
        if (end < 0) {
          return;
        }
        if (!upgraded.isCompleted) {
          upgraded.complete(text.substring(0, end));
        }
        // After the headers: an unmasked text frame "hi" from the server.
        final frame = bytes.sublist(end + 4);
        final whole =
            frame.length >= 4 || (frame.isNotEmpty && frame[0] == 0xC1);
        if (whole && !echoed.isCompleted) {
          // A whole text frame back: compressed (RSV1) when compression was
          // agreed to, else "hi" as it was sent.
          final compressed = frame[0] == 0xC1;
          echoed.complete(
            compressed ||
                (frame[0] == 0x81 &&
                    frame.length >= 4 &&
                    utf8.decode(frame.sublist(2, 4)) == 'hi'),
          );
        }
      },
      onDone: () {
        if (!echoed.isCompleted) {
          echoed.complete(false);
        }
      },
      onError: (Object _) {},
    );
    socket.add(
      latin1.encode(
        'GET /c HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
        'Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
        'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Extensions: $offer\r\n\r\n',
      ),
    );
    final head = await upgraded.future.timeout(const Duration(seconds: 3));
    expect(head, startsWith('HTTP/1.1 101'));
    String? extensions;
    for (final line in head.split('\r\n')) {
      final colon = line.indexOf(':');
      if (colon > 0 &&
          line.substring(0, colon).toLowerCase() ==
              'sec-websocket-extensions') {
        extensions = line.substring(colon + 1).trim();
      }
    }
    // A masked, uncompressed text frame "hi" (mask key 0).
    socket.add(const [0x81, 0x82, 0, 0, 0, 0, 0x68, 0x69]);
    final works = await echoed.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => false,
    );
    return (extensions, works);
  }

  for (final offer in [
    'permessage-deflate; server_max_window_bits=16',
    'permessage-deflate; server_max_window_bits=7',
    'permessage-deflate; server_max_window_bits=0',
    'permessage-deflate; server_max_window_bits=',
    'permessage-deflate; server_max_window_bits',
    'permessage-deflate; server_max_window_bits=abc',
    'permessage-deflate; server_max_window_bits=09',
    'permessage-deflate; client_max_window_bits=16',
    'permessage-deflate; client_max_window_bits=-1',
    'permessage-deflate; server_max_window_bits=10; server_max_window_bits=10',
  ]) {
    test('"$offer": declined, the connection works uncompressed', () async {
      final (extensions, works) = await handshake(offer);
      expect(extensions, isNull);
      expect(works, isTrue);
    });
  }

  for (final offer in [
    'permessage-deflate',
    'permessage-deflate; server_max_window_bits=8',
    'permessage-deflate; server_max_window_bits=15',
    'permessage-deflate; client_max_window_bits',
    'permessage-deflate; client_max_window_bits=12',
  ]) {
    test('"$offer": agreed to', () async {
      final (extensions, works) = await handshake(offer);
      expect(extensions, contains('permessage-deflate'));
      expect(works, isTrue);
    });
  }

  // Forms where a reader may differ from the handshake's own: whatever is
  // decided, it is never agreed to and then broken.
  for (final offer in [
    'permessage-deflate; server_max_window_bits="10"',
    'permessage-deflate; server_max_window_bits="1,0"',
    'permessage-deflate; server_max_window_bits="1;0"',
    'PERMESSAGE-DEFLATE; SERVER_MAX_WINDOW_BITS=16',
    'permessage-deflate; Server_Max_Window_Bits=10',
    'permessage-deflate; server_max_window_bits = 10',
    'permessage-deflate; server_max_window_bits\t=\t10',
    'permessage-deflate; =16',
    'permessage-deflate; server_max_window_bits=10, '
        'permessage-deflate; server_max_window_bits=16',
    'permessage-deflate; server_max_window_bits=16, permessage-deflate',
  ]) {
    test('"$offer": the connection works after a round trip', () async {
      final (extensions, works) = await handshake(offer);
      print('"$offer" -> ${extensions ?? 'declined'}');
      expect(works, isTrue);
    });
  }
}
