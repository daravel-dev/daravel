/// The server reads WebSocket frames itself, between the TCP socket and the
/// [WebSocket] a route's handler gets: a message is limited as a whole, all
/// its fragments together; a message must arrive within a deadline; PING
/// and PONG frames are rate limited per connection; and what waits to be
/// written, control frames included, counts toward the connection's limit.
///
/// The [WebSocket] is handed whole frames only: an unfragmented message as
/// it arrived, a fragmented one as one frame (FIN=1, its first frame's
/// opcode and RSV1, mask key 0000) once complete, and control frames on
/// their own, handled apart from the message they arrive in. The
/// [WebSocket] keeps the handshake, permessage-deflate, UTF-8 and the
/// close and ping timers.
///
/// It works through [WebSocketTransformer.upgrade] with an [HttpRequest]
/// whose `response.detachSocket()` returns the guarded [Socket], which
/// keeps the negotiated permessage-deflate. [HttpRequest], [HttpResponse]
/// and [Socket] are implemented by delegation: a member a newer SDK adds to
/// them is a compile error here, caught by CI, not a `noSuchMethod` at run
/// time.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'buffered_web_socket.dart';

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

  /// The most that may wait to be written to the client, frames and PONGs
  /// included; above it the socket is destroyed (a
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
  WebSocket? _attached;
  bool _violated = false;
  Timer? _grace;

  /// permessage-deflate was agreed to at the handshake: a message's first
  /// frame may carry RSV1.
  bool _deflate = false;

  /// The code and reason of the client's CLOSE, once read: what the
  /// session reports, whatever ends the connection afterwards.
  int? _clientCloseCode;
  String? _clientCloseReason;

  /// The code and reason the guard closed the connection with (a
  /// violation): what the session reports when the client sent no valid
  /// close of its own.
  int? _violationCode;
  String? _violationReason;

  /// [_clientCloseCode], else [_violationCode], to [socket]'s [closeCode].
  void _report(WebSocket? socket) {
    if (socket is! BufferedWebSocket) {
      return;
    }
    final client = _clientCloseCode;
    if (client != null) {
      socket.peerClosed(client, _clientCloseReason);
    } else if (_violationCode case final code?) {
      socket.peerClosed(code, _violationReason);
    }
  }

  /// [request] for [WebSocketTransformer.upgrade]: everything is
  /// [request]'s, except that its response's `detachSocket()` gives the
  /// guarded socket.
  HttpRequest wrap(HttpRequest request) => _GuardedRequest(request, this);

  /// The WebSocket a violation closes with its code, so the close frame is
  /// written between frames. Called twice per connection:
  /// 1. by the engine's `_upgrade` with the upgraded WebSocket, as soon as
  ///    it exists, so a violation in the first frames (before the handler
  ///    runs) closes it;
  /// 2. by `_session` with the BufferedWebSocket over it, which replaces
  ///    the first. Once the application's frames flow, they are bound to
  ///    the upgraded WebSocket through BufferedWebSocket's feed, and
  ///    BufferedWebSocket is what closes it (its queue first unbound).
  ///
  /// Both report [WebSocket.done]; disposing twice does nothing more.
  void attach(WebSocket socket) {
    _attached = socket;
    _report(socket);
    if (socket is BufferedWebSocket) {
      // What was held while nothing read goes on once something does.
      socket.onReader = () => _socket?._flushHeld();
    }
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
    _violationCode = code;
    _violationReason = reason;
    onViolation?.call(code, reason);
    final webSocket = _attached;
    _report(webSocket);
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
      // A WebSocket whose sink is bound refuses at once; the grace below
      // destroys the connection anyway.
    }
    _grace = Timer(limits.closeGrace, () => socket?.destroy());
  }

  void _slowClient() {
    onSlowClient?.call();
    _socket?.destroy();
  }

  /// The client closed (with [code] and [reason]) or went away
  /// ([clientGone]) while the WebSocket did not read, and nothing read it
  /// within [_GuardedSocket.unreadWait]: the session ends with the
  /// client's code. A close is answered with that code, the socket
  /// destroyed after the grace; a client that went away is not waited for.
  void _closedUnread(int? code, String? reason, {required bool clientGone}) {
    final attached = _attached;
    if (attached is BufferedWebSocket) {
      // No close read: 1006 (gone) or 1005 (no code), as RFC 6455 §7.1.5.
      attached.peerClosed(code ?? (clientGone ? 1006 : 1005), reason);
    }
    final socket = _socket;
    if (clientGone || attached == null) {
      socket?.destroy();
      return;
    }
    _keepGrace = true;
    // The answer echoes the client's code when it is 1000 or 3000-4999,
    // else closes with 1000; the reason, already checked as UTF-8 within
    // 123 bytes, goes with it.
    final echo = code == null || code == 1000 || (code >= 3000 && code <= 4999)
        ? code
        : 1000;
    try {
      unawaited(
        attached
            .close(echo, echo == null ? null : reason)
            .then<void>((_) {}, onError: (Object _) {}),
      );
    } on Object {
      // Closing already: the grace below ends it.
    }
    _grace = Timer(limits.closeGrace, () => socket?.destroy());
  }

  /// The socket was destroyed: the session ends now, not when the
  /// BufferedWebSocket's own close gives up waiting for a client that
  /// will not answer.
  void _gone() {
    final attached = _attached;
    if (attached is BufferedWebSocket) {
      // A close the client sent, else the guard's own, stands as the
      // session's code, not the abnormal end of the destroyed socket.
      _report(attached);
      if (attached.closeCode == null && attached.readyState == WebSocket.open) {
        // Gone while open, without a close anyone read (a reset, a failed
        // write while what the client sent was held): 1006, as RFC 6455
        // §7.1.5. A socket this side was closing keeps what it reported.
        attached.peerClosed(1006, null);
      }
      attached.abandon();
    }
  }

  /// The grace stays once a close of the guard's own is under way.
  bool _keepGrace = false;

  void _dispose() {
    _inbound.dispose();
    // After a violation the grace stays: the WebSocket's `done` reports its
    // side closed, and a client that neither answers nor goes away would
    // keep the session until the WebSocket's own close timeout; the grace
    // destroys the socket, which ends the session.
    if (!_violated && !_keepGrace) {
      _grace?.cancel();
    }
  }
}

/// Reads the client's frames (RFC 6455 §5.2) and hands the WebSocket whole
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

  /// The payload goes to the WebSocket as it is (true), or into the message
  /// being assembled (false).
  bool _pass = true;

  /// The frame is the last of a data message (unfragmented or not): its
  /// end ends the message's deadline.
  bool _endsMessage = false;

  /// The payload of a PING being read: the guard answers it itself
  /// ([_GuardedSocket._pong]), in the counted queue.
  BytesBuilder? _ping;

  /// The payload of the client's CLOSE being read: handed on as one frame
  /// once whole, its code known to [_GuardedSocket] (a WebSocket that does
  /// not read yet holds it, [_GuardedSocket._clientClose]).
  BytesBuilder? _close;

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

  /// The frame whose header was just read goes on as it arrived: its
  /// header is handed on by [add], from the chunk when it lies there.
  bool _passHeader = false;

  /// Reads [chunk]; [emit] gets what the WebSocket is to read.
  ///
  /// Frames that go on as they arrived are handed on as one view of the
  /// chunk per run of them, not an object per frame: a client sending tiny
  /// frames costs about what it sends.
  void add(Uint8List chunk, void Function(Uint8List bytes) emit) {
    // The run of [chunk] waiting to be handed on: [runStart, runEnd).
    var runStart = 0;
    var runEnd = 0;
    void flushRun() {
      if (runEnd > runStart) {
        emit(Uint8List.sublistView(chunk, runStart, runEnd));
      }
      runStart = runEnd = 0;
    }

    void extend(int from, int to) {
      if (runEnd > runStart && runEnd == from) {
        runEnd = to;
      } else {
        flushRun();
        runStart = from;
        runEnd = to;
      }
    }

    // Anything else handed on goes after the run, in order.
    void out(Uint8List bytes) {
      flushRun();
      emit(bytes);
    }

    var at = 0;
    while (at < chunk.length && !_stopped) {
      if (!_inPayload) {
        // Where the header starts in this chunk, if it does.
        final headerAt = _headerRead == 0 ? at : -1;
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
          flushRun();
          return;
        }
        final headerLength = _headerNeeded;
        _passHeader = false;
        _headerDone(out);
        _headerRead = 0;
        _headerNeeded = 2;
        if (_stopped) {
          flushRun();
          return;
        }
        if (_passHeader) {
          if (headerAt >= 0) {
            extend(headerAt, at);
          } else {
            // Begun in an earlier chunk: a copy of what was read.
            out(
              Uint8List.fromList(
                Uint8List.sublistView(_header, 0, headerLength),
              ),
            );
          }
        }
        if (_remaining == 0) {
          _payloadDone(out);
        }
        continue;
      }
      final count = min(_remaining, chunk.length - at);
      if (_pass) {
        extend(at, at + count);
      } else {
        final slice = Uint8List.sublistView(chunk, at, at + count);
        final plain = Uint8List(count);
        for (var i = 0; i < count; i++) {
          plain[i] = slice[i] ^ _mask[(_maskOffset + i) & 3];
        }
        _maskOffset += count;
        (_ping ?? _close ?? _message)!.add(plain);
        assert(
          _ping != null || _close != null || _message!.length <= _messageBytes,
          'what is assembled stays within the lengths admitted',
        );
      }
      _remaining -= count;
      at += count;
      if (_remaining == 0) {
        _payloadDone(out);
      }
    }
    flushRun();
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
      // A length with the top bit set is no length (RFC 6455 §5.2): -1,
      // refused below.
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

    // Every frame is checked here (RFC 6455 §5.2, §5.5), before anything
    // is held or handed on, so a frame the protocol refuses is refused
    // whether the handler reads or not.
    if (length < 0 ||
        (length7 == 126 && length < 126) ||
        (length7 == 127 && length < 0x10000)) {
      // A 64-bit length with the top bit set, or a length not in its
      // shortest form.
      return _stop(1002, 'Protocol error');
    }
    if (!masked) {
      // A client's frames are masked (§5.1).
      return _stop(1002, 'Protocol error');
    }
    if (rsv & 0x30 != 0) {
      // RSV2 and RSV3: no extension the server agrees to uses them.
      return _stop(1002, 'Protocol error');
    }
    if (_opcode >= 0x8) {
      // Control frames: CLOSE, PING, PONG.
      if (_opcode > 0xA || rsv != 0 || !_fin || length > 125) {
        // A reserved opcode; RSV1, a fragment or more than 125 bytes on a
        // control frame (§5.5).
        return _stop(1002, 'Protocol error');
      }
      if (_opcode == 0x8 && length == 1) {
        // A close payload is empty or holds a 2-byte code (§5.5.1).
        return _stop(1002, 'Protocol error');
      }
      if ((_opcode == 0x9 || _opcode == 0xA) && !_takeToken()) {
        return _stop(1008, 'Too many control frames');
      }
      if (_opcode == 0x8 && _message != null) {
        // A close in the middle of a message: the message is dropped.
        _message = null;
        _deadline?.cancel();
      }
      if (_opcode == 0x9) {
        // A PING: answered here, its PONG in the guard's counted queue
        // between frames, so it counts toward maxBufferedBytes.
        _ping = BytesBuilder(copy: false);
        _pass = false;
        _inPayload = _remaining > 0;
        return;
      }
      if (_opcode == 0x8) {
        // A CLOSE: read whole and checked, then handed on as one frame.
        _close = BytesBuilder(copy: false);
        _pass = false;
        _inPayload = _remaining > 0;
        return;
      }
      return _passFrame();
    }
    if (_opcode > 0x2) {
      // Reserved data opcodes 0x3-0x7.
      return _stop(1002, 'Protocol error');
    }
    if (_opcode == 0x1 || _opcode == 0x2) {
      if (_message != null) {
        return _stop(1002, 'A new message before the last one ended');
      }
      if (rsv & 0x40 != 0 && !_guard._deflate) {
        // RSV1 marks a compressed message, which only permessage-deflate
        // agreed to at the handshake allows.
        return _stop(1002, 'Protocol error');
      }
      if (length > _limits.maxMessageBytes) {
        return _stop(1009, 'Message too big');
      }
      _startDeadline();
      if (_fin) {
        _endsMessage = true;
        return _passFrame();
      }
      _message = BytesBuilder(copy: false);
      _messageOpcode = _opcode;
      _messageRsv1 = (rsv & 0x40) != 0;
      _messageBytes = length;
      assert(
        _messageBytes >= 0 && _messageBytes <= _limits.maxMessageBytes,
        'the message stays within its limit',
      );
      _pass = false;
      _inPayload = _remaining > 0;
      return;
    }
    // A continuation.
    if (_message == null || rsv != 0) {
      // No message to continue, or RSV1 on a continuation (only a
      // message's first frame carries it).
      return _stop(1002, 'Protocol error');
    }
    // What is left of the limit, so no sum of lengths can overflow:
    // 0 <= _messageBytes <= maxMessageBytes holds here.
    if (length > _limits.maxMessageBytes - _messageBytes) {
      return _stop(1009, 'Message too big');
    }
    _messageBytes += length;
    assert(
      _messageBytes >= 0 && _messageBytes <= _limits.maxMessageBytes,
      'the message stays within its limit',
    );
    _pass = false;
    _inPayload = _remaining > 0;
  }

  /// The frame goes on as it arrived; [add] hands its header on.
  void _passFrame() {
    _pass = true;
    _passHeader = true;
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
    final close = _close;
    if (close != null) {
      _close = null;
      _pass = true;
      final payload = close.takeBytes();
      final code = payload.length >= 2 ? payload[0] << 8 | payload[1] : null;
      if (code != null && !isClientCloseCode(code)) {
        return _stop(1002, 'Invalid close code');
      }
      String? reason;
      if (payload.length > 2) {
        try {
          reason = utf8.decode(Uint8List.sublistView(payload, 2));
        } on FormatException {
          // The reason is UTF-8 (§5.5.1); data that is not is 1007 (§7.4.1).
          return _stop(1007, 'Invalid UTF-8 in the close reason');
        }
      }
      emit(_frame(0x8, false, payload.length));
      if (payload.isNotEmpty) {
        emit(payload);
      }
      _guard._socket?._clientClose(code, reason);
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

  /// Whether a client may close with [code] (RFC 6455 §7.4.1 and the IANA
  /// registry of §11.7): 1000-1003, 1007-1014 and 3000-4999. 1004, 1005,
  /// 1006 and 1015 are never sent, and the rest is reserved.
  static bool isClientCloseCode(int code) =>
      (code >= 1000 && code <= 1003) ||
      (code >= 1007 && code <= 1014) ||
      (code >= 3000 && code <= 4999);

  /// The header of one whole masked frame with key 0000 (a client's frames
  /// are masked, RFC 6455 §5.3; XOR with 0 changes nothing).
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
    _close = null;
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
    // The handshake's answer says whether compression was agreed to; no
    // frame has been read yet.
    // All its values, joined: a header given more than once is read, not
    // refused.
    _guard._deflate = (_inner.headers['sec-websocket-extensions'] ?? const [])
        .join(',')
        .contains('permessage-deflate');
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

/// Small slices held together, in order, as one buffer.
final class _HeldBytes {
  final BytesBuilder builder = BytesBuilder();
}

/// The end of the client's TCP stream, held in order behind its bytes.
final class _TcpEnd {
  _TcpEnd(this.error, this.stackTrace);

  /// Null for a FIN; the socket's error for a reset.
  final Object? error;
  final StackTrace? stackTrace;
}

/// The TCP socket under the upgraded WebSocket.
///
/// In: the client's bytes through [_Inbound]; while the WebSocket pauses
/// its reading they wait in [_held], up to a bound past which TCP holds
/// the client back. Out:
/// everything the WebSocket writes (frames, the close frame) and the
/// guard's PONGs go through [addStream] in order, to the TCP socket only
/// while the socket takes it (not paused); what waits is counted: above
/// [WebSocketGuardLimits.maxBufferedBytes] the socket is destroyed.
final class _GuardedSocket extends Stream<Uint8List> implements Socket {
  _GuardedSocket(this._inner, this._guard);

  final Socket _inner;
  final WebSocketGuard _guard;

  StreamSubscription<Uint8List>? _reading;

  /// What the client sent that waits for the WebSocket to read again: byte
  /// slices in order, then perhaps the end of the TCP stream ([_TcpEnd]).
  ///
  /// The client is read on while the WebSocket does not read (a handler
  /// that has not listened yet, or one that never does), so its close or
  /// its going away is seen; TCP holds it back once more than
  /// [_heldLimit] bytes wait. At most [_heldLimit] plus one assembled
  /// message (up to `maxMessageBytes`) plus one TCP chunk wait here.
  final Queue<Object> _held = Queue<Object>();
  int _heldBytes = 0;

  /// The WebSocket paused its reading.
  bool _handOnPaused = false;

  /// TCP is paused because [_held] is over [_heldLimit].
  bool _tcpHeldBack = false;

  /// How many bytes may wait in [_held] before TCP is held back.
  static const int heldLimit = 64 << 10;
  int get _heldLimit => min(heldLimit, _guard.limits.maxMessageBytes);

  /// How long a close or the end of TCP that waits in [_held] waits for
  /// the WebSocket to read it, before the session ends without it.
  static const Duration unreadWait = Duration(seconds: 5);
  Timer? _unreadWait;

  /// Something reads the WebSocket ([BufferedWebSocket.isRead]): the
  /// application, the server's drain, or the WebSocket's own close. Until
  /// then what arrives is held here, within the bound of [_held].
  bool get _readerPresent =>
      !_readerGone &&
      _guard._attached is BufferedWebSocket &&
      (_guard._attached! as BufferedWebSocket).isRead;

  /// What arrives may go to the WebSocket now.
  bool get _passing => !_handOnPaused && _readerPresent;

  /// [bytes] to the WebSocket, handed on at a 16-byte offset in their
  /// buffer (a slice that starts elsewhere is copied); held while it does
  /// not read or nothing reads it.
  void _handOn(Uint8List bytes) {
    if (_readerGone) {
      // Checked already ([_Inbound]); nothing can read it: dropped.
      return;
    }
    if (!_passing || _held.isNotEmpty) {
      _hold(bytes);
      if (!_tcpHeldBack && _heldBytes > _heldLimit) {
        _tcpHeldBack = true;
        _reading?.pause();
        if (!_appListens) {
          // Held back with nothing reading: the application has the
          // unread wait to listen ([_unreadExpired]).
          _startUnreadWait();
        }
      }
      return;
    }
    _in.add(
      (bytes.offsetInBytes & 15) == 0 ? bytes : Uint8List.fromList(bytes),
    );
  }

  /// What one held item costs beyond its bytes: the object and its slot in
  /// the queue. Measured at about 55 bytes for a 2-byte frame and 95 for a
  /// 6-byte one held alone; 128 bounds both.
  static const int heldItemCost = 128;

  /// Slices below this many bytes are merged into the held buffer before
  /// them ([_HeldBytes]), so a client sending tiny frames costs about what
  /// it sends, not an object per frame.
  static const int mergeBelow = 1 << 10;

  /// A merged buffer stops taking slices at this size.
  static const int mergedSize = 16 << 10;

  /// [bytes] into [_held]: merged when small, as they are when not (a
  /// slice that does not start at a 16-byte offset copied).
  void _hold(Uint8List bytes) {
    if (bytes.length < mergeBelow) {
      final last = _held.isEmpty ? null : _held.last;
      if (last is _HeldBytes && last.builder.length < mergedSize) {
        last.builder.add(bytes);
        _heldBytes += bytes.length;
        return;
      }
      _held.add(_HeldBytes()..builder.add(bytes));
      _heldBytes += heldItemCost + bytes.length;
      return;
    }
    // A view of a larger buffer (the TCP chunk) would keep all of it: held
    // as a copy of its own bytes, at offset 0.
    _held.add(
      bytes.offsetInBytes == 0 &&
              bytes.lengthInBytes == bytes.buffer.lengthInBytes
          ? bytes
          : Uint8List.fromList(bytes),
    );
    _heldBytes += heldItemCost + bytes.length;
  }

  /// [_flushHeld] is handing items on: the WebSocket can pause and resume
  /// inside one of them (its controller is synchronous), and the resume
  /// must not hand on the next item before this one is done.
  bool _flushing = false;

  /// Hands on what [_held] holds, in order, while the WebSocket reads.
  void _flushHeld() {
    if (_flushing) {
      return; // the loop below goes on once the current item is handed on
    }
    _flushing = true;
    try {
      while (_passing && _held.isNotEmpty && !_destroyed) {
        final item = _held.removeFirst();
        if (item is Uint8List) {
          _heldBytes -= heldItemCost + item.length;
          _in.add(item);
        } else if (item is _HeldBytes) {
          // A fresh buffer: at offset 0, so handed on as it is.
          final bytes = item.builder.takeBytes();
          _heldBytes -= heldItemCost + bytes.length;
          _in.add(bytes);
        } else if (item is _TcpEnd) {
          _endIn(item);
        }
      }
    } finally {
      _flushing = false;
    }
    assert(_heldBytes >= 0, 'what is held is counted once');
    if (_held.isEmpty || _appListens) {
      // Read, or listened to (a listener that pauses keeps what waits):
      // nothing is given up.
      _unreadWait?.cancel();
      _unreadWait = null;
    }
    if (_tcpHeldBack && _heldBytes <= _heldLimit) {
      _tcpHeldBack = false;
      _reading?.resume();
    }
  }

  void _endIn(_TcpEnd end) {
    final error = end.error;
    if (error != null) {
      _in.addError(error, end.stackTrace);
    } else {
      unawaited(_in.close());
    }
  }

  /// The application listens to the socket (paused or not). Only before
  /// it does is what waits in [_held] given up after [unreadWait]: a
  /// listener that reads slowly gets everything, the close included, and
  /// one that stays paused for good keeps the session, as any WebSocket
  /// whose reader stalls does.
  bool get _appListens =>
      !_readerGone &&
      _guard._attached is BufferedWebSocket &&
      (_guard._attached! as BufferedWebSocket).isListened;

  /// The client's TCP stream ended (FIN) or failed (RST).
  void _tcpEnd([Object? error, StackTrace? stackTrace]) {
    final end = _TcpEnd(error, stackTrace);
    if (_readerGone) {
      // No reader can come: the session ends now.
      _held.clear();
      _heldBytes = 0;
      _guard._closedUnread(
        _guard._clientCloseCode,
        _guard._clientCloseReason,
        clientGone: true,
      );
      return;
    }
    if (_passing && _held.isEmpty) {
      _endIn(end);
    } else if (_held.isEmpty && !_appListens) {
      // Nothing waits that a reader could still want: the session ends.
      _guard._closedUnread(null, null, clientGone: true);
    } else {
      _held.add(end);
      if (!_appListens) {
        _startUnreadWait();
      }
    }
  }

  /// The client's CLOSE was read (and handed on, or held).
  bool _closeRead = false;

  /// The client's CLOSE was handed on, with [code] and [reason]; if it
  /// waits in [_held] and the application has not listened, it has
  /// [unreadWait] to do so.
  void _clientClose(int? code, String? reason) {
    _closeRead = true;
    _guard._clientCloseCode = code;
    _guard._clientCloseReason = reason;
    if (_readerGone) {
      // No reader can come: the session ends now, with the client's code.
      _held.clear();
      _heldBytes = 0;
      _guard._closedUnread(code, reason, clientGone: false);
      return;
    }
    if (_held.isNotEmpty && !_appListens) {
      _startUnreadWait();
    }
  }

  /// Gives the application [unreadWait] to listen: started when the
  /// client's close or the end of TCP waits in [_held], or when [_held] is
  /// full and TCP holds the client back, while the application has not
  /// listened. Cancelled once it listens or nothing waits ([_flushHeld]).
  void _startUnreadWait() {
    _unreadWait ??= Timer(unreadWait, _unreadExpired);
  }

  void _unreadExpired() {
    _unreadWait = null;
    if (_held.isEmpty || _destroyed || _appListens) {
      return; // read in time, or listened to: nothing is given up
    }
    // Nobody read: what waits is dropped, and the session ends.
    final ended = _held.last is _TcpEnd;
    _held.clear();
    _heldBytes = 0;
    if (ended || _closeRead) {
      _guard._closedUnread(
        _guard._clientCloseCode,
        _guard._clientCloseReason,
        clientGone: ended,
      );
      return;
    }
    // Full, and TCP holds the client back: its close could not be read
    // either. The server ends the session, and reads on what the client
    // still sends (within [discardAfterViolation]) so its answer and its
    // end are seen.
    _guard._violation(1008, 'The application did not read');
    if (_tcpHeldBack) {
      _tcpHeldBack = false;
      _reading?.resume();
    }
  }

  /// What the client may still send after a violation, read and dropped:
  /// enough for its close frame and what was in flight, so the connection
  /// ends with a FIN and the client sees the close code. Past it, reading
  /// stops and TCP holds the client back (a socket destroyed with unread
  /// bytes is reset, and the client may lose the close frame, which one
  /// that floods on can do without).
  static const int discardAfterViolation = 4 << 20;
  int _discarded = 0;

  void _read(Uint8List chunk) {
    if (_guard._violated) {
      _discarded += chunk.length;
      if (_discarded > discardAfterViolation) {
        // A pause of its own, which no resume from the WebSocket undoes.
        _reading?.pause();
      }
      return;
    }
    _guard._inbound.add(chunk, _handOn);
  }

  /// What the WebSocket reads: the client's frames, through [_Inbound].
  late final StreamController<Uint8List> _in = StreamController<Uint8List>(
    sync: true,
    onListen: () {
      _reading = _inner.listen(_read, onError: _tcpEnd, onDone: _tcpEnd);
    },
    // The client is read on while the WebSocket pauses ([_held]).
    onPause: () => _handOnPaused = true,
    onResume: () {
      _handOnPaused = false;
      _flushHeld();
    },
    onCancel: () {
      if (!_destroyed &&
          !_guard._violated &&
          _guard._attached?.readyState == WebSocket.open) {
        // The application cancelled its subscription and kept the socket:
        // the client is read on and what it sends dropped, as the server's
        // own read for a handler that never listens does, so its close or
        // its going away still ends the session. Frames are still checked.
        _readerGone = true;
        _held.clear();
        _heldBytes = 0;
        _unreadWait?.cancel();
        _unreadWait = null;
        if (_tcpHeldBack) {
          _tcpHeldBack = false;
          _reading?.resume();
        }
        return null;
      }
      return _reading?.cancel();
    },
  );

  /// The application cancelled its subscription while the socket stayed
  /// open: nothing reads what arrives any more, and nothing can (a
  /// WebSocket is listened to once).
  bool _readerGone = false;

  final Queue<List<int>> _waiting = Queue<List<int>>();
  int _waitingBytes = 0;
  bool _paused = false;

  /// What the TCP socket writes, fed from [_waiting] while not paused.
  late final StreamController<List<int>> _out = StreamController<List<int>>(
    sync: true,
    onPause: () {
      _paused = true;
      // The WebSocket waits too: the application's frames stay in
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

  /// The subscription to what the WebSocket writes.
  StreamSubscription<List<int>>? _writing;

  /// The TCP socket's `addStream` of [_out], once something was written.
  Future<void>? _written;
  bool _closing = false;
  bool _finishing = false;
  bool _destroyed = false;
  final Completer<void> _closed = Completer<void>();

  // Where the WebSocket's frames begin and end, so a PONG goes between
  // them (a frame's header and payload can come as separate chunks).
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

  /// What the WebSocket writes, in order.
  @override
  Future<void> addStream(Stream<List<int>> stream) {
    final finished = Completer<void>();
    _writing = stream.listen(
      _fromWebSocket,
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
  void add(List<int> data) => _fromWebSocket(data);

  void _fromWebSocket(List<int> data) {
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

  /// Answers a client's PING with [payload], between the WebSocket's frames.
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

  /// Follows the frames the WebSocket writes (a server's are not masked; RFC 6455
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
    // A write that fails (the client reset the connection) ends it here
    // too: what the WebSocket and the application still write is dropped,
    // and the WebSocket's reading ends, so the session does.
    _written ??= _inner
        .addStream(_out.stream)
        .then<void>((_) {}, onError: (Object _) => destroy());
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
    _held.clear();
    _heldBytes = 0;
    _unreadWait?.cancel();
    _unreadWait = null;
    // The WebSocket still sees its stream end, so its close completes.
    _writing?.resume();
    _guard._dispose();
    _guard._gone();
    unawaited(_reading?.cancel());
    _inner.destroy();
    unawaited(_out.close());
    unawaited(_in.close());
    if (!_closed.isCompleted) {
      _closed.complete();
    }
  }

  // These three are not used on a detached WebSocket socket; they
  // delegate.

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
