/// A guard in front of `dart:io`'s WebSocket, between it and the TCP
/// socket: it assembles fragmented messages itself, limits control frames,
/// and counts what waits to be written.
///
/// `dart:io` (Dart 3.13) limits each frame (`maxPayloadLength`), not a
/// message: fragments with FIN=0 were collected without end; a PING between
/// fragments corrupted the message (control and data frames share one
/// payload buffer); and every PING was answered with a PONG queued without
/// back-pressure, from a client that does not read. The guard passes
/// `dart:io` only whole frames: an unfragmented message as it arrived, a
/// fragmented one as one frame (FIN=1, its first frame's opcode and RSV1,
/// mask key 0000) once complete, and control frames on their own, never
/// inside a message. `dart:io` keeps the handshake, permessage-deflate (it
/// limits the decompressed message), UTF-8, close and ping timers.
///
/// It works through [WebSocketTransformer.upgrade] with an [HttpRequest]
/// whose `response.detachSocket()` returns the guarded [Socket]:
/// `WebSocket.fromUpgradedSocket` would lose permessage-deflate (it passes
/// no negotiated deflate). [HttpRequest], [HttpResponse] and [Socket] are
/// implemented by delegation: a member a newer SDK adds to them is a
/// compile error here, caught by CI, not a `noSuchMethod` at run time.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// The limits of a [WebSocketGuard].
final class WebSocketGuardLimits {
  /// Limits of one connection.
  const WebSocketGuardLimits({
    required this.maxMessageBytes,
    required this.maxBufferedBytes,
    this.assembleTimeout = const Duration(seconds: 30),
    this.controlFrameBurst = 20,
    this.controlFramesPerSecond = 5,
    this.closeGrace = const Duration(seconds: 1),
  });

  /// The most a message may hold as it arrives (compressed, when
  /// compressed), all its fragments together; above it the connection is
  /// closed with 1009.
  final int maxMessageBytes;

  /// The most that may wait to be written to the client, frames and the
  /// PONGs `dart:io` sends included; above it the socket is destroyed (a
  /// client that does not read would not read a close frame either).
  final int maxBufferedBytes;

  /// How long a message may take from its first byte to its last; longer
  /// is closed with 1008. A message of 1 MiB over a slow mobile network is
  /// within 30 s.
  final Duration assembleTimeout;

  /// PING and PONG frames a client may send at once ([controlFrameBurst])
  /// and per second after that; more is closed with 1008. Clients ping
  /// every few seconds at most.
  final int controlFrameBurst;

  /// See [controlFrameBurst].
  final int controlFramesPerSecond;

  /// After a close for a violation, the socket is destroyed this much
  /// later whatever the client does.
  final Duration closeGrace;
}

/// Guards one WebSocket connection ([wrap] before
/// [WebSocketTransformer.upgrade], then [attach] the upgraded socket).
final class WebSocketGuard {
  /// A guard with [limits]; [onViolation] hears why it closed a connection
  /// (for the log), [onSlowClient] that a client read too slowly.
  WebSocketGuard(this.limits, {this.onViolation, this.onSlowClient});

  /// Its limits.
  final WebSocketGuardLimits limits;

  /// Told the close code and reason of a violation.
  final void Function(int code, String reason)? onViolation;

  /// Told that more than [WebSocketGuardLimits.maxBufferedBytes] waited.
  final void Function()? onSlowClient;

  late final _Inbound _inbound = _Inbound(this);
  _GuardedSocket? _socket;
  WebSocket? _webSocket;
  bool _violated = false;
  Timer? _grace;

  /// [request] for [WebSocketTransformer.upgrade]: everything is
  /// [request]'s, except that its response's `detachSocket()` gives the
  /// guarded socket.
  HttpRequest wrap(HttpRequest request) => _GuardedRequest(request, this);

  /// The WebSocket `dart:io` made over the guarded socket: a violation
  /// closes it with its code, so the close frame is written between
  /// frames.
  void attach(WebSocket socket) {
    _webSocket = socket;
    unawaited(
      socket.done.then<void>(
        (_) => _dispose(),
        onError: (Object _) => _dispose(),
      ),
    );
  }

  void _violation(int code, String reason) {
    if (_violated) {
      return;
    }
    _violated = true;
    onViolation?.call(code, reason);
    final webSocket = _webSocket;
    final socket = _socket;
    if (webSocket == null) {
      socket?.destroy();
      return;
    }
    try {
      unawaited(
        webSocket
            .close(code, reason)
            .then<void>((_) {}, onError: (Object _) {}),
      );
    } on Object {
      // A dart:io socket whose sink is bound refuses at once; the grace
      // below destroys the connection anyway.
    }
    _grace = Timer(limits.closeGrace, () => socket?.destroy());
  }

  void _slowClient() {
    onSlowClient?.call();
    _socket?.destroy();
  }

  void _dispose() {
    _inbound.dispose();
    _grace?.cancel();
  }
}

/// Reads the client's frames (RFC 6455 §5.2) and passes `dart:io` whole
/// frames only.
final class _Inbound {
  _Inbound(this._guard);

  final WebSocketGuard _guard;
  WebSocketGuardLimits get _limits => _guard.limits;

  // The header being read: at most 2 + 8 + 4 bytes.
  final Uint8List _header = Uint8List(14);
  int _headerRead = 0;
  int _headerNeeded = 2;

  // The frame whose payload is being read.
  bool _inPayload = false;
  bool _fin = false;
  int _opcode = 0;
  final Uint8List _mask = Uint8List(4);
  int _remaining = 0;
  int _maskOffset = 0;

  /// The payload goes to `dart:io` as it is (true), or into the message
  /// being assembled (false).
  bool _pass = true;

  /// The frame is the last of a data message (unfragmented or not): its
  /// end ends the message's deadline.
  bool _endsMessage = false;

  /// The payload of a PING being read: the guard answers it itself
  /// ([_GuardedSocket._pong]), so `dart:io` queues no PONG of its own.
  BytesBuilder? _ping;

  // The fragmented message being assembled.
  BytesBuilder? _message;
  int _messageOpcode = 0;
  bool _messageRsv1 = false;
  int _messageBytes = 0;
  Timer? _deadline;

  // Control frames: a token bucket.
  late double _tokens = _limits.controlFrameBurst.toDouble();
  final Stopwatch _clock = Stopwatch()..start();
  int _lastRefill = 0;

  bool _stopped = false;

  /// Reads [chunk]; [emit] gets what `dart:io` is to read.
  void add(Uint8List chunk, void Function(Uint8List bytes) emit) {
    var at = 0;
    while (at < chunk.length && !_stopped) {
      if (!_inPayload) {
        while (at < chunk.length && _headerRead < _headerNeeded) {
          _header[_headerRead++] = chunk[at++];
          if (_headerRead == 2) {
            final length7 = _header[1] & 0x7F;
            final masked = (_header[1] & 0x80) != 0;
            _headerNeeded =
                2 +
                (length7 == 126
                    ? 2
                    : length7 == 127
                    ? 8
                    : 0) +
                (masked ? 4 : 0);
          }
        }
        if (_headerRead < _headerNeeded) {
          return;
        }
        _headerDone(emit);
        _headerRead = 0;
        _headerNeeded = 2;
        if (_stopped) {
          return;
        }
        if (_remaining == 0) {
          _payloadDone(emit);
        }
        continue;
      }
      final count = min(_remaining, chunk.length - at);
      final slice = Uint8List.sublistView(chunk, at, at + count);
      if (_pass) {
        emit(slice);
      } else {
        final plain = Uint8List(count);
        for (var i = 0; i < count; i++) {
          plain[i] = slice[i] ^ _mask[(_maskOffset + i) & 3];
        }
        _maskOffset += count;
        (_ping ?? _message)!.add(plain);
      }
      _remaining -= count;
      at += count;
      if (_remaining == 0) {
        _payloadDone(emit);
      }
    }
  }

  void _headerDone(void Function(Uint8List bytes) emit) {
    final first = _header[0];
    final second = _header[1];
    _fin = (first & 0x80) != 0;
    final rsv = first & 0x70;
    _opcode = first & 0x0F;
    final masked = (second & 0x80) != 0;
    final length7 = second & 0x7F;
    var offset = 2;
    int length;
    if (length7 == 126) {
      length = _header[2] << 8 | _header[3];
      offset = 4;
    } else if (length7 == 127) {
      // A length with the top bit set is no length (dart:io refuses it).
      length = (_header[2] & 0x80) != 0 ? -1 : 0;
      if (length == 0) {
        for (var i = 2; i < 10; i++) {
          length = length << 8 | _header[i];
        }
      }
      offset = 10;
    } else {
      length = length7;
    }
    if (masked) {
      _mask.setRange(0, 4, _header, offset);
    } else {
      _mask.fillRange(0, 4, 0);
    }
    _maskOffset = 0;
    _remaining = length < 0 ? 0 : length;
    _endsMessage = false;
    final headerBytes = Uint8List.fromList(
      Uint8List.sublistView(_header, 0, _headerNeeded),
    );

    if (_opcode >= 0x8) {
      // Control frames: CLOSE, PING, PONG (others dart:io refuses).
      if ((_opcode == 0x9 || _opcode == 0xA) && !_takeToken()) {
        return _stop(1008, 'Too many control frames');
      }
      if (_opcode == 0x8 && _message != null) {
        // A close in the middle of a message: the message is dropped.
        _message = null;
        _deadline?.cancel();
      }
      if (_opcode == 0x9 && _fin && masked && length >= 0 && length <= 125) {
        // A valid PING: answered here, its PONG in the guard's counted
        // queue between frames. dart:io answering it would queue the PONG
        // where nothing counts it while the client does not read.
        _ping = BytesBuilder(copy: false);
        _pass = false;
        _inPayload = _remaining > 0;
        return;
      }
      return _passFrame(headerBytes, length, emit);
    }
    if (_opcode == 0x1 || _opcode == 0x2) {
      if (_message != null) {
        return _stop(1002, 'A new message before the last one ended');
      }
      if (length < 0 || length > _limits.maxMessageBytes) {
        return _stop(1009, 'Message too big');
      }
      _startDeadline();
      if (_fin) {
        _endsMessage = true;
        return _passFrame(headerBytes, length, emit);
      }
      if (!masked || rsv & 0x30 != 0) {
        return _stop(1002, 'Protocol error');
      }
      _message = BytesBuilder(copy: false);
      _messageOpcode = _opcode;
      _messageRsv1 = (rsv & 0x40) != 0;
      _messageBytes = length;
      _pass = false;
      _inPayload = _remaining > 0;
      return;
    }
    if (_opcode == 0x0 && _message != null) {
      if (!masked || rsv != 0) {
        return _stop(1002, 'Protocol error');
      }
      if (length < 0 || _messageBytes + length > _limits.maxMessageBytes) {
        return _stop(1009, 'Message too big');
      }
      _messageBytes += length;
      _pass = false;
      _inPayload = _remaining > 0;
      return;
    }
    // A continuation with no message, a reserved opcode: dart:io refuses
    // it, as it did without the guard.
    _passFrame(headerBytes, length, emit);
  }

  void _passFrame(
    Uint8List headerBytes,
    int length,
    void Function(Uint8List bytes) emit,
  ) {
    _pass = true;
    emit(headerBytes);
    _inPayload = _remaining > 0;
  }

  void _payloadDone(void Function(Uint8List bytes) emit) {
    _inPayload = false;
    if (_pass) {
      if (_endsMessage) {
        _deadline?.cancel();
      }
      return;
    }
    final ping = _ping;
    if (ping != null) {
      _ping = null;
      // Back to the message being assembled, if any.
      _pass = _message == null;
      _guard._socket?._pong(ping.takeBytes());
      return;
    }
    if (!_fin) {
      return;
    }
    final payload = _message!.takeBytes();
    _message = null;
    _deadline?.cancel();
    emit(_frame(_messageOpcode, _messageRsv1, payload.length));
    if (payload.isNotEmpty) {
      emit(payload);
    }
  }

  /// The header of one whole masked frame with key 0000 (dart:io requires
  /// a client's frames to be masked; XOR with 0 changes nothing).
  static Uint8List _frame(int opcode, bool rsv1, int length) {
    final builder = BytesBuilder()..addByte(0x80 | (rsv1 ? 0x40 : 0) | opcode);
    if (length < 126) {
      builder.addByte(0x80 | length);
    } else if (length < 0x10000) {
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

  bool _takeToken() {
    final now = _clock.elapsedMilliseconds;
    _tokens = min(
      _limits.controlFrameBurst.toDouble(),
      _tokens + (now - _lastRefill) / 1000 * _limits.controlFramesPerSecond,
    );
    _lastRefill = now;
    if (_tokens < 1) {
      return false;
    }
    _tokens -= 1;
    return true;
  }

  void _startDeadline() {
    _deadline?.cancel();
    _deadline = Timer(
      _limits.assembleTimeout,
      () => _stop(1008, 'Message not completed in time'),
    );
  }

  void _stop(int code, String reason) {
    _stopped = true;
    _message = null;
    _deadline?.cancel();
    _guard._violation(code, reason);
  }

  void dispose() {
    _stopped = true;
    _message = null;
    _ping = null;
    _deadline?.cancel();
  }
}

/// [_inner] with its response's `detachSocket()` guarded.
final class _GuardedRequest extends StreamView<Uint8List>
    implements HttpRequest {
  _GuardedRequest(this._inner, WebSocketGuard guard)
    : response = _GuardedResponse(_inner.response, guard),
      super(_inner);

  final HttpRequest _inner;

  @override
  final HttpResponse response;

  @override
  int get contentLength => _inner.contentLength;

  @override
  String get method => _inner.method;

  @override
  Uri get uri => _inner.uri;

  @override
  Uri get requestedUri => _inner.requestedUri;

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  bool get persistentConnection => _inner.persistentConnection;

  @override
  X509Certificate? get certificate => _inner.certificate;

  @override
  HttpSession get session => _inner.session;

  @override
  String get protocolVersion => _inner.protocolVersion;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;
}

/// [_inner], whose detached socket is guarded.
final class _GuardedResponse implements HttpResponse {
  _GuardedResponse(this._inner, this._guard);

  final HttpResponse _inner;
  final WebSocketGuard _guard;

  @override
  Future<Socket> detachSocket({bool writeHeaders = true}) async {
    final socket = _GuardedSocket(
      await _inner.detachSocket(writeHeaders: writeHeaders),
      _guard,
    );
    _guard._socket = socket;
    return socket;
  }

  @override
  int get contentLength => _inner.contentLength;
  @override
  set contentLength(int value) => _inner.contentLength = value;

  @override
  int get statusCode => _inner.statusCode;
  @override
  set statusCode(int value) => _inner.statusCode = value;

  @override
  String get reasonPhrase => _inner.reasonPhrase;
  @override
  set reasonPhrase(String value) => _inner.reasonPhrase = value;

  @override
  bool get persistentConnection => _inner.persistentConnection;
  @override
  set persistentConnection(bool value) => _inner.persistentConnection = value;

  @override
  Duration? get deadline => _inner.deadline;
  @override
  set deadline(Duration? value) => _inner.deadline = value;

  @override
  bool get bufferOutput => _inner.bufferOutput;
  @override
  set bufferOutput(bool value) => _inner.bufferOutput = value;

  @override
  Encoding get encoding => _inner.encoding;
  @override
  set encoding(Encoding value) => _inner.encoding = value;

  @override
  HttpHeaders get headers => _inner.headers;

  @override
  List<Cookie> get cookies => _inner.cookies;

  @override
  HttpConnectionInfo? get connectionInfo => _inner.connectionInfo;

  @override
  Future<void> redirect(
    Uri location, {
    int status = HttpStatus.movedTemporarily,
  }) => _inner.redirect(location, status: status);

  @override
  void add(List<int> data) => _inner.add(data);

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _inner.addError(error, stackTrace);

  @override
  Future<void> addStream(Stream<List<int>> stream) => _inner.addStream(stream);

  @override
  Future<void> close() => _inner.close();

  @override
  Future<void> get done => _inner.done;

  @override
  Future<void> flush() => _inner.flush();

  @override
  void write(Object? object) => _inner.write(object);

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      _inner.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _inner.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => _inner.writeln(object);
}

/// The TCP socket under `dart:io`'s WebSocket.
///
/// In: the client's bytes through [_Inbound]; `dart:io` pausing its reading
/// pauses the TCP socket, so nothing new queues here. Out: everything
/// `dart:io` writes (frames, PONGs, the close frame) comes through
/// [addStream] in order; it goes to the TCP socket only while the socket
/// takes it (not paused), and what waits is counted: above
/// [WebSocketGuardLimits.maxBufferedBytes] the socket is destroyed.
final class _GuardedSocket extends Stream<Uint8List> implements Socket {
  _GuardedSocket(this._inner, this._guard);

  final Socket _inner;
  final WebSocketGuard _guard;

  StreamSubscription<Uint8List>? _reading;

  /// [bytes] to `dart:io`, at an offset that is a multiple of 16: its
  /// unmasking (`_WebSocketProtocolTransformer._unmask`) aligns the index
  /// within a buffer to 16 bytes and views it as `Int32x4List`, which
  /// throws unless the buffer itself starts on 16 bytes (a socket's chunks
  /// always do; a slice after a frame header does not), and the connection
  /// failed with 1002 for any frame of 16 bytes or more.
  void _toDartIo(Uint8List bytes) => _in.add(
    (bytes.offsetInBytes & 15) == 0 ? bytes : Uint8List.fromList(bytes),
  );

  /// What `dart:io` reads: the client's frames, through [_Inbound].
  late final StreamController<Uint8List> _in = StreamController<Uint8List>(
    sync: true,
    onListen: () {
      _reading = _inner.listen(
        (chunk) => _guard._inbound.add(chunk, _toDartIo),
        onError: _in.addError,
        onDone: _in.close,
      );
    },
    onPause: () => _reading?.pause(),
    onResume: () => _reading?.resume(),
    onCancel: () => _reading?.cancel(),
  );

  final Queue<List<int>> _waiting = Queue<List<int>>();
  int _waitingBytes = 0;
  bool _paused = false;

  /// What the TCP socket writes, fed from [_waiting] while not paused.
  late final StreamController<List<int>> _out = StreamController<List<int>>(
    sync: true,
    onPause: () {
      _paused = true;
      // dart:io waits too: the application's frames stay in
      // BufferedWebSocket's queue, which closes a slow client with its
      // route's code (4100 for Pusher, 1008 otherwise).
      _writing?.pause();
    },
    onResume: () {
      _paused = false;
      _drain();
      if (!_paused) {
        _writing?.resume();
      }
    },
  );

  /// The subscription to what dart:io writes.
  StreamSubscription<List<int>>? _writing;

  /// The TCP socket's `addStream` of [_out], once something was written.
  Future<void>? _written;
  bool _closing = false;
  bool _finishing = false;
  bool _destroyed = false;
  final Completer<void> _closed = Completer<void>();

  // Where dart:io's frames begin and end, so a PONG goes between them
  // (dart:io writes a frame's header and payload as separate chunks).
  final Uint8List _outHeader = Uint8List(14);
  int _outHeaderRead = 0;
  int _outHeaderNeeded = 2;
  int _outRemaining = 0;

  /// PONGs waiting for the end of the frame being written.
  final List<Uint8List> _pongs = [];

  bool get _betweenFrames => _outRemaining == 0 && _outHeaderRead == 0;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => _in.stream.listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  /// What `dart:io` writes, in order.
  @override
  Future<void> addStream(Stream<List<int>> stream) {
    final finished = Completer<void>();
    _writing = stream.listen(
      _fromDartIo,
      onError: (Object error, StackTrace stackTrace) {
        if (!finished.isCompleted) {
          finished.completeError(error, stackTrace);
        }
      },
      onDone: () {
        if (!finished.isCompleted) {
          finished.complete();
        }
      },
      cancelOnError: true,
    );
    if (_paused) {
      _writing!.pause();
    }
    return finished.future;
  }

  @override
  void add(List<int> data) => _fromDartIo(data);

  void _fromDartIo(List<int> data) {
    if (_destroyed || data.isEmpty) {
      return;
    }
    _track(data);
    _write(data);
    if (_betweenFrames && _pongs.isNotEmpty) {
      for (final pong in _pongs) {
        _waitingBytes -= pong.length;
        _write(pong);
      }
      _pongs.clear();
    }
  }

  /// Answers a client's PING with [payload], between dart:io's frames.
  void _pong(Uint8List payload) {
    if (_destroyed) {
      return;
    }
    final frame = Uint8List(2 + payload.length)
      ..[0] = 0x8A
      ..[1] = payload.length
      ..setRange(2, 2 + payload.length, payload);
    if (_betweenFrames) {
      _write(frame);
      return;
    }
    _pongs.add(frame);
    _waitingBytes += frame.length;
    _checkLimit();
  }

  /// Follows the frames dart:io writes (a server's are not masked; RFC 6455
  /// §5.2), to know when one has ended.
  void _track(List<int> data) {
    var at = 0;
    while (at < data.length) {
      if (_outRemaining > 0) {
        final count = min(_outRemaining, data.length - at);
        _outRemaining -= count;
        at += count;
        continue;
      }
      _outHeader[_outHeaderRead++] = data[at++];
      if (_outHeaderRead == 2) {
        final length7 = _outHeader[1] & 0x7F;
        _outHeaderNeeded =
            2 +
            (length7 == 126
                ? 2
                : length7 == 127
                ? 8
                : 0) +
            ((_outHeader[1] & 0x80) != 0 ? 4 : 0);
      }
      if (_outHeaderRead >= 2 && _outHeaderRead == _outHeaderNeeded) {
        final length7 = _outHeader[1] & 0x7F;
        var length = length7;
        if (length7 == 126) {
          length = _outHeader[2] << 8 | _outHeader[3];
        } else if (length7 == 127) {
          length = 0;
          for (var i = 2; i < 10; i++) {
            length = length << 8 | _outHeader[i];
          }
        }
        _outRemaining = length;
        _outHeaderRead = 0;
        _outHeaderNeeded = 2;
      }
    }
  }

  void _write(List<int> data) {
    // The TCP socket reads from [_out]; it pauses it while the OS does not
    // take more, which is what [_paused] follows.
    _written ??= _inner
        .addStream(_out.stream)
        .then<void>((_) {}, onError: (Object _) {});
    if (!_paused && _waiting.isEmpty) {
      _out.add(data);
      return;
    }
    _waiting.add(data);
    _waitingBytes += data.length;
    _checkLimit();
  }

  void _checkLimit() {
    if (_waitingBytes > _guard.limits.maxBufferedBytes) {
      _guard._slowClient();
    }
  }

  void _drain() {
    while (!_paused && _waiting.isNotEmpty && !_destroyed) {
      final data = _waiting.removeFirst();
      _waitingBytes -= data.length;
      _out.add(data);
    }
    if (_closing && _waiting.isEmpty) {
      unawaited(_finishClose());
    }
  }

  /// Closes once everything waiting is written.
  @override
  Future<void> close() {
    _closing = true;
    if (_waiting.isEmpty) {
      unawaited(_finishClose());
    }
    return _closed.future;
  }

  Future<void> _finishClose() async {
    if (_finishing || _destroyed) {
      return;
    }
    _finishing = true;
    try {
      final written = _written;
      if (written != null) {
        await _out.close();
        await written;
      }
      await _inner.close();
    } on Object {
      // The client is gone: closed is closed.
    } finally {
      if (!_closed.isCompleted) {
        _closed.complete();
      }
    }
  }

  @override
  void destroy() {
    if (_destroyed) {
      return;
    }
    _destroyed = true;
    _waiting.clear();
    _waitingBytes = 0;
    _pongs.clear();
    // dart:io must still see its stream end (its close waits for it).
    _writing?.resume();
    _guard._dispose();
    unawaited(_reading?.cancel());
    _inner.destroy();
    unawaited(_out.close());
    unawaited(_in.close());
    if (!_closed.isCompleted) {
      _closed.complete();
    }
  }

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
  void write(Object? object) => add(encoding.encode('$object'));

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) =>
      write(objects.join(separator));

  @override
  void writeCharCode(int charCode) => write(String.fromCharCode(charCode));

  @override
  void writeln([Object? object = '']) => write('$object\n');

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
