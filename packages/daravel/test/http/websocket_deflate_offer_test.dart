import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// One connection's client side: the 101 head, then server frames
/// (unmasked), inflated with one inflater for the connection when RSV1 is
/// set.
final class _Client {
  _Client(this.socket) {
    socket.listen(
      (chunk) {
        _bytes.add(chunk);
        if (!head.isCompleted) {
          final all = _bytes.toBytes();
          final end = latin1.decode(all).indexOf('\r\n\r\n');
          if (end < 0) {
            return;
          }
          final text = latin1.decode(all.sublist(0, end));
          head.complete(text);
          // Frames follow a 101 only; after a refusal comes its body.
          _upgraded = text.startsWith('HTTP/1.1 101');
          _bytes
            ..clear()
            ..add(all.sublist(end + 4));
        }
        if (_upgraded) {
          _parse();
        }
      },
      onDone: _end,
      onError: (Object _) => _end(),
    );
  }

  final Socket socket;
  final Completer<String> head = Completer<String>();
  bool _upgraded = false;
  final BytesBuilder _bytes = BytesBuilder();
  final List<Completer<String?>> _waiting = [];
  final List<String?> _messages = [];
  final RawZLibFilter _inflater = RawZLibFilter.inflateFilter(
    raw: true,
    windowBits: 15,
  );

  void _end() {
    if (!head.isCompleted) {
      head.complete('');
    }
    for (final waiting in _waiting) {
      waiting.complete(null);
    }
    _waiting.clear();
  }

  void _parse() {
    final data = _bytes.toBytes();
    var at = 0;
    while (data.length - at >= 2) {
      var length = data[at + 1] & 0x7F;
      var offset = at + 2;
      if (length == 126) {
        if (data.length - at < 4) break;
        length = data[at + 2] << 8 | data[at + 3];
        offset = at + 4;
      }
      if (data.length < offset + length) break;
      var payload = data.sublist(offset, offset + length);
      final opcode = data[at] & 0x0F;
      if ((data[at] & 0x40) != 0) {
        final input = [...payload, 0x00, 0x00, 0xFF, 0xFF];
        _inflater.process(input, 0, input.length);
        final out = <int>[];
        for (
          var c = _inflater.processed(flush: true);
          c != null;
          c = _inflater.processed(flush: true)
        ) {
          out.addAll(c);
        }
        payload = Uint8List.fromList(out);
      }
      if (opcode == 0x1) {
        final text = utf8.decode(payload, allowMalformed: true);
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(text);
        } else {
          _messages.add(text);
        }
      } else if (opcode == 0x8) {
        _end();
      }
      at = offset + length;
    }
    _bytes
      ..clear()
      ..add(data.sublist(at));
  }

  /// The next text message, or null when the connection ended or 3 s
  /// passed.
  Future<String?> next() {
    if (_messages.isNotEmpty) {
      return Future.value(_messages.removeAt(0));
    }
    final waiting = Completer<String?>();
    _waiting.add(waiting);
    return waiting.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => null,
    );
  }

  /// A masked text frame of [text] (mask key 0); compressed (RSV1) with
  /// [windowBits] when given.
  void send(String text, {int? windowBits}) {
    var payload = utf8.encode(text);
    var first = 0x81;
    if (windowBits != null) {
      final filter = RawZLibFilter.deflateFilter(
        raw: true,
        windowBits: windowBits,
      )..process(payload, 0, payload.length);
      final out = <int>[];
      for (
        var c = filter.processed(flush: true);
        c != null;
        c = filter.processed(flush: true)
      ) {
        out.addAll(c);
      }
      payload = Uint8List.fromList(out.sublist(0, out.length - 4));
      first = 0xC1;
    }
    socket.add([first, 0x80 | payload.length, 0, 0, 0, 0, ...payload]);
  }
}

/// On a route with `compress: true`, a client's permessage-deflate offer
/// is agreed to only when the server would read the same window sizes the
/// handshake agrees to, from the same reading of the header: a window size
/// RFC 7692 does not allow (8 to 15), or any quote or backslash in the
/// header, is declined and the connection works uncompressed. Every offer
/// agreed to exchanges a compressed and a plain message.
void main() {
  late Application app;
  late ServerEngine engine;
  late MemoryHandler log;

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
      logger: Logger(handlers: [log = MemoryHandler()]),
    );
    await engine.start();
  });

  tearDown(() async {
    await engine.stop();
    await app.shutdown();
  });

  /// The handshake for [offer]: the extension agreed to (null when none),
  /// and whether a compressed message (when agreed) and a plain one each
  /// come back as sent.
  Future<(String?, bool)> handshake(String offer) async {
    final socket = await Socket.connect('127.0.0.1', engine.port!);
    addTearDown(socket.destroy);
    final client = _Client(socket);
    socket.add(
      latin1.encode(
        'GET /c HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
        'Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
        'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Extensions: $offer\r\n\r\n',
      ),
    );
    final head = await client.head.future.timeout(const Duration(seconds: 3));
    expect(head, startsWith('HTTP/1.1 101'), reason: offer);
    String? extensions;
    for (final line in head.split('\r\n')) {
      final colon = line.indexOf(':');
      if (colon > 0 &&
          line.substring(0, colon).toLowerCase() ==
              'sec-websocket-extensions') {
        extensions = line.substring(colon + 1).trim();
      }
    }
    var works = true;
    if (extensions != null) {
      // The window the client may use: what the server agreed to.
      final bits = int.parse(
        RegExp(r'max_window_bits=(\d+)').firstMatch(extensions)?.group(1) ??
            '15',
      );
      client.send('compressed', windowBits: bits);
      works = await client.next() == 'compressed';
    }
    client.send('plain');
    works = works && await client.next() == 'plain';
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
    // A comma inside quotes: one offer for the handshake, whatever a
    // reader splitting on commas sees.
    'permessage-deflate; foo="a,b"; server_max_window_bits=16',
    'permessage-deflate; foo="a,b"; server_max_window_bits=7',
    'permessage-deflate; foo="a,b"; server_max_window_bits=0',
    'permessage-deflate; foo="a,b"; server_max_window_bits=10; '
        'server_max_window_bits=16',
    'permessage-deflate; foo="a,b"; client_max_window_bits=16',
    // Quotes before, after, unclosed, a backslash inside: declined.
    'permessage-deflate; server_max_window_bits=10; foo="a,b"',
    'permessage-deflate; foo="x"; server_max_window_bits=10',
    r'permessage-deflate; foo="a\"b"; server_max_window_bits=10',
    r'permessage-deflate; foo=a\b; server_max_window_bits=10',
    'permessage-deflate; server_max_window_bits="10"',
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
    'permessage-deflate; server_max_window_bits=10',
    'permessage-deflate; server_max_window_bits=15',
    'permessage-deflate; client_max_window_bits',
    'permessage-deflate; client_max_window_bits=12',
    'permessage-deflate; server_max_window_bits=10; '
        'server_max_window_bits=10',
  ]) {
    test('"$offer": agreed to, a compressed and a plain message come '
        'back', () async {
      final (extensions, works) = await handshake(offer);
      expect(extensions, contains('permessage-deflate'));
      expect(works, isTrue);
    });
  }

  for (final (name, offer) in [
    (
      'an unclosed quote',
      'permessage-deflate; foo="a,b; server_max_window_bits=10',
    ),
    ('a value that does not parse', 'permessage-deflate; a b'),
    (
      'a window size that does not parse',
      'permessage-deflate; server_max_window_bits=1 0',
    ),
  ]) {
    test(
      '$name: refused (400) or declined, never agreed to, no error',
      () async {
        final socket = await Socket.connect('127.0.0.1', engine.port!);
        addTearDown(socket.destroy);
        final client = _Client(socket);
        socket.add(
          latin1.encode(
            'GET /c HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
            'Connection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
            'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Extensions: '
            '$offer\r\n\r\n',
          ),
        );
        final head = await client.head.future.timeout(
          const Duration(seconds: 3),
        );
        expect(
          head,
          anyOf(startsWith('HTTP/1.1 400'), startsWith('HTTP/1.1 101')),
        );
        expect(head.toLowerCase(), isNot(contains('sec-websocket-extensions')));
        expect(log.records.where((r) => r.level == LogLevel.error), isEmpty);
      },
    );
  }

  // Forms another reader may take differently: whatever is decided, it
  // is never agreed to and then broken.
  for (final offer in [
    'PERMESSAGE-DEFLATE; SERVER_MAX_WINDOW_BITS=16',
    'permessage-deflate; Server_Max_Window_Bits=10',
    'permessage-deflate; server_max_window_bits = 10',
    'permessage-deflate; server_max_window_bits\t=\t10',
    'permessage-deflate; =16',
    'permessage-deflate; server_max_window_bits=10, '
        'permessage-deflate; server_max_window_bits=16',
    'permessage-deflate; server_max_window_bits=16, permessage-deflate',
    'permessage-deflate; server_max_window_bits=10; '
        'server_max_window_bits=16',
  ]) {
    test('"$offer": the connection works after a round trip', () async {
      final (extensions, works) = await handshake(offer);
      print('"$offer" -> ${extensions ?? 'declined'}');
      expect(works, isTrue);
    });
  }
}
