// A minimal reproduction, with dart:io alone, of a WebSocket server
// failing a valid frame: `dart run tool/repro/websocket_unmask_offset.dart`.
//
// dart:io's `_WebSocketProtocolTransformer._unmask` aligns the index within
// the received buffer to 16 bytes, then views the buffer as `Int32x4List`
// from `buffer.offsetInBytes + index`. A socket's chunks always start at
// offset 0, so this holds there; a stream whose chunks are views at another
// offset (a proxy, a guard between the TCP socket and the WebSocket) has
// every masked frame of 16 bytes or more fail with 1002. The script sends
// the same 32-byte masked frame twice: once in chunks at offset 0 (it is
// echoed), once in chunks at offset 1 (the connection is closed).

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Future<void> main() async {
  for (final offset in [0, 1]) {
    final outcome = await _run(offset);
    stdout.writeln('chunks at offset $offset: $outcome');
  }
}

Future<String> _run(int offset) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final result = Completer<String>();
  server.listen((socket) async {
    final upgraded = await _handshake(socket);
    final webSocket = WebSocket.fromUpgradedSocket(
      _Offset(upgraded, offset),
      serverSide: true,
    );
    webSocket.listen(
      (message) => result.complete('echoed ${(message as List<int>).length}'),
      onDone: () {
        if (!result.isCompleted) {
          result.complete('closed ${webSocket.closeCode}');
        }
      },
    );
    await result.future;
    await webSocket.close();
    await upgraded.cancel();
  });
  final client = await Socket.connect('127.0.0.1', server.port);
  client.add(
    latin1.encode(
      'GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\n'
      'Connection: Upgrade\r\n'
      'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
      'Sec-WebSocket-Version: 13\r\n\r\n',
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 200));
  // One binary frame of 32 bytes, masked as a client must.
  const mask = [1, 2, 3, 4];
  client.add([
    0x82,
    0x80 | 32,
    ...mask,
    for (var i = 0; i < 32; i++) i ^ mask[i & 3],
  ]);
  final outcome = await result.future.timeout(const Duration(seconds: 5));
  client.destroy();
  await server.close();
  return outcome;
}

/// Reads the HTTP request off [socket] and answers 101; the socket then
/// carries frames.
Future<_Upgraded> _handshake(Socket socket) async {
  final upgraded = _Upgraded(socket);
  await upgraded.head;
  upgraded.reading.pause();
  socket.add(
    latin1.encode(
      'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n'
      'Connection: Upgrade\r\n'
      // base64(sha1(key + GUID)) for the key above (RFC 6455 §1.3).
      'Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n',
    ),
  );
  return upgraded;
}

/// [socket] read up to the end of the HTTP request ([head]); what came
/// after it is [rest], and [reading] goes on with the frames.
final class _Upgraded {
  _Upgraded(this.socket) {
    reading = socket.listen((chunk) {
      if (_head.isCompleted) {
        return;
      }
      _pending.add(chunk);
      final bytes = _pending.toBytes();
      final end = latin1.decode(bytes).indexOf('\r\n\r\n');
      if (end >= 0) {
        rest = Uint8List.fromList(bytes.sublist(end + 4));
        _head.complete();
      }
    });
  }

  final Socket socket;
  late final StreamSubscription<Uint8List> reading;
  final BytesBuilder _pending = BytesBuilder();
  final Completer<void> _head = Completer<void>();
  Uint8List rest = Uint8List(0);

  Future<void> get head => _head.future;

  Future<void> cancel() => reading.cancel();
}

/// [_upgraded]'s socket, whose chunks are handed on as views starting at
/// [_offset] bytes into a larger buffer: the same bytes, another offset.
final class _Offset extends Stream<Uint8List> implements Socket {
  _Offset(this._upgraded, this._offset);

  final _Upgraded _upgraded;
  final int _offset;
  Socket get _inner => _upgraded.socket;

  Uint8List _shift(Uint8List chunk) {
    final buffer = Uint8List(_offset + chunk.length)
      ..setRange(_offset, _offset + chunk.length, chunk);
    return Uint8List.sublistView(buffer, _offset);
  }

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final controller = StreamController<Uint8List>();
    if (_upgraded.rest.isNotEmpty) {
      controller.add(_shift(_upgraded.rest));
    }
    _upgraded.reading
      ..onData((chunk) => controller.add(_shift(chunk)))
      ..onDone(controller.close)
      ..resume();
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);
  @override
  void add(List<int> data) => _inner.add(data);
  @override
  Future<void> close() => _inner.close();
  @override
  void destroy() => _inner.destroy();
  @override
  Future<void> get done => _inner.done;
  @override
  Future<void> flush() => _inner.flush();
  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);
  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;
  @override
  void write(Object? object) => _inner.write(object);
  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);
  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);
  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
  @override
  int get port => _inner.port;
  @override
  int get remotePort => _inner.remotePort;
  @override
  InternetAddress get address => _inner.address;
  @override
  InternetAddress get remoteAddress => _inner.remoteAddress;
  @override
  bool setOption(SocketOption option, bool enabled) =>
      _inner.setOption(option, enabled);
  @override
  Uint8List getRawOption(RawSocketOption option) => _inner.getRawOption(option);
  @override
  void setRawOption(RawSocketOption option) => _inner.setRawOption(option);
}
