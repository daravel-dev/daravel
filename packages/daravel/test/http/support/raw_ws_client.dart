import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:test/test.dart';

/// A frame the server sent.
final class WsFrame {
  WsFrame(this.opcode, this.payload);
  final int opcode;
  final Uint8List payload;

  int? get closeCode =>
      payload.length >= 2 ? payload[0] << 8 | payload[1] : null;
}

/// A WebSocket client that writes frames by hand (masked, as a client
/// must) and reads the server's frames (unmasked), with permessage-deflate
/// when asked for.
final class RawWsClient {
  RawWsClient._(this.socket, this.deflate) {
    // One subscription (a socket is listened to once): the 101 response
    // first, then frames.
    _subscription = socket.listen(
      (chunk) {
        _bytes.add(chunk);
        if (!_upgraded.isCompleted) {
          final all = _bytes.toBytes();
          final text = latin1.decode(all);
          final end = text.indexOf('\r\n\r\n');
          if (end < 0) {
            return;
          }
          _bytes.clear();
          if (!text.startsWith('HTTP/1.1 101')) {
            _upgraded.completeError(StateError(text));
            return;
          }
          _upgraded.complete();
          _bytes.add(Uint8List.sublistView(all, end + 4));
        }
        _parse();
      },
      onDone: () => ended = true,
      onError: (Object _) => ended = true,
    );
    // A write the server no longer reads (it closed the connection) fails
    // through `done`: the peer went away, as when reading ends.
    unawaited(
      socket.done.then<void>((_) {}, onError: (Object _) => ended = true),
    );
  }

  final Completer<void> _upgraded = Completer<void>();

  final Socket socket;
  final bool deflate;
  late final StreamSubscription<Uint8List> _subscription;
  final BytesBuilder _bytes = BytesBuilder();
  final List<WsFrame> _frames = [];
  final List<Completer<WsFrame>> _waiting = [];
  bool ended = false;

  /// The server's close frame arrived (and was read).
  bool closeReceived = false;
  static final Random _random = Random();

  static const String _key = 'dGhlIHNhbXBsZSBub25jZQ==';

  static String _request(String path, {required bool deflate}) =>
      'GET $path HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\n'
      'Connection: Upgrade\r\nSec-WebSocket-Key: $_key\r\n'
      'Sec-WebSocket-Version: 13\r\n'
      '${deflate ? 'Sec-WebSocket-Extensions: permessage-deflate\r\n' : ''}'
      '\r\n';

  /// The handshake's response headers (lower-case names).
  static Future<Map<String, String>> handshake(
    int port,
    String path, {
    bool deflate = false,
  }) async {
    final socket = await Socket.connect('127.0.0.1', port);
    socket.add(latin1.encode(_request(path, deflate: deflate)));
    final text = StringBuffer();
    await for (final chunk in socket.timeout(const Duration(seconds: 5))) {
      text.write(latin1.decode(chunk));
      if (text.toString().contains('\r\n\r\n')) {
        break;
      }
    }
    socket.destroy();
    final lines = text.toString().split('\r\n\r\n').first.split('\r\n');
    expect(lines.first, startsWith('HTTP/1.1 101'));
    return {
      for (final line in lines.skip(1))
        line.substring(0, line.indexOf(':')).toLowerCase(): line
            .substring(line.indexOf(':') + 1)
            .trim(),
    };
  }

  static Future<RawWsClient> connect(
    int port,
    String path, {
    bool deflate = false,
  }) async {
    final client = RawWsClient._(
      await Socket.connect('127.0.0.1', port),
      deflate,
    );
    client.socket.add(latin1.encode(_request(path, deflate: deflate)));
    await client._upgraded.future.timeout(const Duration(seconds: 5));
    return client;
  }

  static Uint8List header(
    int opcode,
    int length, {
    bool fin = true,
    bool rsv1 = false,
  }) {
    final builder = BytesBuilder()
      ..addByte((fin ? 0x80 : 0) | (rsv1 ? 0x40 : 0) | opcode);
    if (length < 126) {
      builder.addByte(0x80 | length);
    } else if (length < 65536) {
      builder
        ..addByte(0x80 | 126)
        ..addByte(length >> 8)
        ..addByte(length & 0xFF);
    } else {
      builder.addByte(0x80 | 127);
      for (var shift = 56; shift >= 0; shift -= 8) {
        builder.addByte((length >> shift) & 0xFF);
      }
    }
    builder.add(const [0, 0, 0, 0]);
    return builder.takeBytes();
  }

  /// A masked frame (key 0000 for [header]; a random key here).
  static Uint8List frame(
    int opcode,
    List<int> payload, {
    bool fin = true,
    bool rsv1 = false,
  }) {
    final builder = BytesBuilder()
      ..addByte((fin ? 0x80 : 0) | (rsv1 ? 0x40 : 0) | opcode);
    final length = payload.length;
    if (length < 126) {
      builder.addByte(0x80 | length);
    } else if (length < 65536) {
      builder
        ..addByte(0x80 | 126)
        ..addByte(length >> 8)
        ..addByte(length & 0xFF);
    } else {
      builder.addByte(0x80 | 127);
      for (var shift = 56; shift >= 0; shift -= 8) {
        builder.addByte((length >> shift) & 0xFF);
      }
    }
    final mask = [for (var i = 0; i < 4; i++) _random.nextInt(256)];
    builder.add(mask);
    builder.add([for (var i = 0; i < length; i++) payload[i] ^ mask[i & 3]]);
    return builder.takeBytes();
  }

  void send(
    int opcode,
    List<int> payload, {
    bool fin = true,
    bool rsv1 = false,
  }) {
    if (!ended) {
      socket.add(frame(opcode, payload, fin: fin, rsv1: rsv1));
    }
  }

  /// [payload] as one message: compressed when [deflate].
  void sendWhole(int opcode, List<int> payload) {
    if (deflate) {
      send(opcode, _compress(payload), rsv1: true);
    } else {
      send(opcode, payload);
    }
  }

  /// [payload] as one message in [pieces] fragments (of the compressed
  /// bytes when [deflate]), a ping between some of them.
  void sendFragmented(
    int opcode,
    List<int> payload, {
    required int pieces,
    Random? random,
  }) {
    final bytes = deflate ? _compress(payload) : payload;
    final cuts = <int>{0, bytes.length};
    final r = random ?? Random(1);
    while (cuts.length < min(pieces + 1, bytes.length + 1)) {
      cuts.add(r.nextInt(bytes.length + 1));
    }
    final points = cuts.toList()..sort();
    if (points.length < 2) {
      points.add(bytes.length);
    }
    for (var i = 0; i + 1 < points.length; i++) {
      final last = i + 2 == points.length;
      send(
        i == 0 ? opcode : 0x0,
        bytes.sublist(points[i], points[i + 1]),
        fin: last,
        rsv1: deflate && i == 0,
      );
      if (!last && r.nextInt(3) == 0) {
        send(0x9, utf8.encode('p$i'));
      }
    }
    if (points.length == 2 && bytes.isEmpty) {
      return;
    }
  }

  /// [payload] as permessage-deflate sends it (RFC 7692 §7.2.1): raw
  /// deflate with a sync flush, its trailing 00 00 FF FF left out. A fresh
  /// compressor per message (no context taken over) is allowed.
  static List<int> _compress(List<int> payload) {
    final filter = RawZLibFilter.deflateFilter(raw: true, windowBits: 15)
      ..process(payload, 0, payload.length);
    final out = <int>[];
    for (
      var chunk = filter.processed(flush: true);
      chunk != null;
      chunk = filter.processed(flush: true)
    ) {
      out.addAll(chunk);
    }
    return out.length >= 4 ? out.sublist(0, out.length - 4) : out;
  }

  /// The server takes its context over between messages: one inflater for
  /// the connection.
  final RawZLibFilter _inflater = RawZLibFilter.inflateFilter(
    raw: true,
    windowBits: 15,
  );

  List<int> _inflate(List<int> payload) {
    final input = [...payload, 0x00, 0x00, 0xFF, 0xFF];
    _inflater.process(input, 0, input.length);
    final out = <int>[];
    for (
      var chunk = _inflater.processed(flush: true);
      chunk != null;
      chunk = _inflater.processed(flush: true)
    ) {
      out.addAll(chunk);
    }
    return out;
  }

  void _parse() {
    var data = _bytes.toBytes();
    var at = 0;
    while (data.length - at >= 2) {
      final first = data[at];
      final second = data[at + 1];
      var length = second & 0x7F;
      var offset = at + 2;
      if (length == 126) {
        if (data.length - at < 4) break;
        length = data[at + 2] << 8 | data[at + 3];
        offset = at + 4;
      } else if (length == 127) {
        if (data.length - at < 10) break;
        length = 0;
        for (var i = 2; i < 10; i++) {
          length = length << 8 | data[at + i];
        }
        offset = at + 10;
      }
      if (data.length < offset + length) break;
      var payload = Uint8List.fromList(data.sublist(offset, offset + length));
      final opcode = first & 0x0F;
      if ((first & 0x40) != 0 && deflate) {
        payload = Uint8List.fromList(_inflate(payload));
      }
      _deliver(WsFrame(opcode, payload));
      at = offset + length;
    }
    _bytes.clear();
    if (at < data.length) {
      _bytes.add(data.sublist(at));
    }
    data = Uint8List(0);
  }

  void _deliver(WsFrame frame) {
    if (frame.opcode == 0x8) {
      closeReceived = true;
    }
    if (_waiting.isNotEmpty) {
      _waiting.removeAt(0).complete(frame);
    } else {
      _frames.add(frame);
    }
  }

  /// The next data frame, control frames (pongs) skipped.
  Future<WsFrame> nextMessage() async {
    while (true) {
      final frame = await next();
      if (frame.opcode < 0x8) {
        return frame;
      }
    }
  }

  Future<WsFrame> next() {
    if (_frames.isNotEmpty) {
      return Future.value(_frames.removeAt(0));
    }
    final waiting = Completer<WsFrame>();
    _waiting.add(waiting);
    return waiting.future.timeout(const Duration(seconds: 10));
  }

  /// The close code the server sent (frames before it are skipped), or
  /// null when it ended without one.
  Future<int?> closeFrame() async {
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (DateTime.now().isBefore(deadline)) {
      for (final frame in [..._frames]) {
        if (frame.opcode == 0x8) {
          return frame.closeCode;
        }
      }
      if (ended && _frames.every((f) => f.opcode != 0x8)) {
        return null;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    throw TimeoutException('no close frame');
  }

  /// Stops reading the socket: what the server sends waits in TCP.
  void pauseReading() => _subscription.pause();

  /// Reads again.
  void resumeReading() => _subscription.resume();

  Future<void> close() async {
    send(0x8, const [0x03, 0xE8]);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await _subscription.cancel();
    socket.destroy();
  }
}
