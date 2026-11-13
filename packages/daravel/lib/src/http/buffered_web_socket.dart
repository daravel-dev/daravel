import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// The WebSocket a `router.ws` handler gets: `dart:io`'s, with a bound on
/// what waits to be sent.
///
/// `dart:io` queues everything added to a WebSocket whose peer reads too
/// slowly (a phone on a bad network, a paused tab, a client that stopped
/// reading) in the Dart heap, with no limit and no way to see it. Here the
/// frames go to the socket through one stream it pulls from: a frame is
/// handed over only while the socket accepts more, the rest waits in a
/// queue that is counted, and once more than [maxBufferedBytes] wait the
/// queue is dropped and the connection is closed with [slowClientCode], so
/// the client reconnects and the server stops holding its backlog.
///
/// After [close] starts (or the peer closed) frames are dropped instead of
/// throwing `StateError: StreamSink is closed`, so a publish racing a close
/// does nothing.
final class BufferedWebSocket extends Stream<dynamic> implements WebSocket {
  /// Wraps [inner], closing it with [slowClientCode] once more than
  /// [maxBufferedBytes] wait to be sent; [onSlowClient] is told when.
  BufferedWebSocket(
    this._inner, {
    required this.maxBufferedBytes,
    this.slowClientCode = WebSocketStatus.policyViolation,
    this.slowClientReason = 'Slow consumer',
    this.onSlowClient,
  });

  final WebSocket _inner;

  /// How many bytes (characters, for text frames) may wait to be sent
  /// before the connection is closed.
  final int maxBufferedBytes;

  /// The close code sent to a client that reads too slowly.
  final int slowClientCode;

  /// The close reason sent with [slowClientCode].
  final String slowClientReason;

  /// Called once when this connection is closed for reading too slowly.
  final void Function()? onSlowClient;

  /// How long [close] waits for queued frames to go out before dropping
  /// them: a peer that stopped reading must not hold a close for ever.
  static const Duration closeGrace = Duration(seconds: 5);

  final ListQueue<Object> _queue = ListQueue<Object>();
  int _bufferedBytes = 0;
  _Feed? _feed;
  Future<void>? _binding;
  bool _closing = false;
  bool _overflowed = false;
  Future<void>? _closed;

  /// Bytes (characters, for text frames) waiting to be sent.
  int get bufferedBytes => _bufferedBytes;

  /// Whether this connection was closed for reading too slowly.
  bool get isSlowClient => _overflowed;

  /// Whether anything listened to what the client sends (the handler,
  /// `Broadcast.pipe`).
  bool get isListened => _listened;
  bool _listened = false;

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _listened = true;
    return _inner.listen(
      onData,
      onError: onError,
      onDone: () {
        _peerClosed();
        onDone?.call();
      },
      cancelOnError: cancelOnError,
    );
  }

  /// The peer closed or went away: what waits cannot reach it, and the
  /// socket is closed from this side too. Before, a handler that never
  /// wrote nor closed kept the connection's session (its scope, its slot
  /// in the server's list) until the server stopped.
  void _peerClosed() {
    if (_closing) {
      return;
    }
    _closed ??= _close(null, null, drop: true);
  }

  @override
  Duration? get pingInterval => _inner.pingInterval;

  @override
  set pingInterval(Duration? interval) => _inner.pingInterval = interval;

  @override
  int get readyState => _closing && _inner.readyState == WebSocket.open
      ? WebSocket.closing
      : _inner.readyState;

  @override
  String get extensions => _inner.extensions;

  @override
  String? get protocol => _inner.protocol;

  @override
  int? get closeCode => _inner.closeCode;

  @override
  String? get closeReason => _inner.closeReason;

  /// Completes when the socket is closed, or [closeGrace] after this side
  /// closed it when the peer never answers (it stopped reading, so the
  /// close frame waits behind the backlog for as long as it stalls).
  @override
  Future<dynamic> get done =>
      Future.any<dynamic>([_inner.done, _gaveUp.future]);

  final Completer<void> _gaveUp = Completer<void>();

  @override
  void add(dynamic data) {
    if (_closing) {
      return;
    }
    final Object frame = switch (data) {
      final String text => text,
      final List<int> bytes => bytes,
      _ => throw ArgumentError.value(
        data,
        'data',
        'A WebSocket frame is a String or a List<int>',
      ),
    };
    final feed = _feed ??= _bind();
    _queue.add(frame);
    _bufferedBytes += _sizeOf(frame);
    feed.flush();
    if (_bufferedBytes > maxBufferedBytes) {
      _overflow();
    }
  }

  @override
  void addUtf8Text(List<int> bytes) => add(utf8.decode(bytes));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    // The frames queued so far go first; the error ends the stream after.
    unawaited(
      _unbind(drop: false).then((_) => _inner.addError(error, stackTrace)),
    );
  }

  @override
  Future<dynamic> addStream(Stream<dynamic> stream) async {
    await for (final data in stream) {
      if (_closing) {
        break;
      }
      add(data);
      // Pull no faster than the socket sends.
      final feed = _feed;
      if (feed != null && _queue.isNotEmpty) {
        await feed.drained();
      }
    }
  }

  @override
  Future<dynamic> close([int? code, String? reason]) =>
      _closed ??= _close(code, reason, drop: false);

  /// Drops the backlog and closes the connection as a slow client.
  void _overflow() {
    if (_overflowed) {
      return;
    }
    _overflowed = true;
    onSlowClient?.call();
    _closed ??= _close(slowClientCode, slowClientReason, drop: true);
  }

  Future<void> _close(int? code, String? reason, {required bool drop}) async {
    _closing = true;
    await _unbind(drop: drop);
    final closing = _inner
        .close(code, reason)
        .then<void>(
          (_) {},
          onError: (Object _) {
            // The socket is gone already; closing it again changes nothing.
          },
        );
    final grace = Timer(closeGrace, () {
      if (!_gaveUp.isCompleted) {
        _gaveUp.complete();
      }
    });
    await Future.any<void>([closing, _gaveUp.future]);
    grace.cancel();
  }

  _Feed _bind() {
    final feed = _Feed(this);
    _binding = _inner
        .addStream(feed)
        .then<void>(
          (_) {},
          onError: (Object _) {
            // The peer went away mid-frame: nothing left to send to.
          },
        );
    return feed;
  }

  /// Ends the stream feeding the socket, so `dart:io` lets go of its sink
  /// (a sink bound to a stream refuses `close`). Without [drop] the queued
  /// frames go out first, for at most [closeGrace].
  Future<void> _unbind({required bool drop}) async {
    final feed = _feed;
    if (feed == null) {
      return;
    }
    if (drop) {
      _queue.clear();
      _bufferedBytes = 0;
    }
    feed.endWhenEmpty();
    if (_queue.isNotEmpty) {
      final grace = Timer(closeGrace, () {
        _queue.clear();
        _bufferedBytes = 0;
        feed.endWhenEmpty();
      });
      await _binding;
      grace.cancel();
    } else {
      await _binding;
    }
  }

  /// The next frame for the socket, if one waits.
  Object? _take() {
    if (_queue.isEmpty) {
      return null;
    }
    final frame = _queue.removeFirst();
    _bufferedBytes -= _sizeOf(frame);
    return frame;
  }

  /// The socket stopped reading from the feed for good (the peer closed):
  /// what waits will never be sent.
  void _detached() {
    _queue.clear();
    _bufferedBytes = 0;
    if (_closing) {
      return; // close() is on its way already
    }
    _closing = true;
    // Unbound, dart:io closes the sink when its target is done; bound, it
    // waits for a close() that nobody would make, and `done` never
    // completes. Make it, once the sink lets go of the feed.
    _closed ??= (_binding ?? Future<void>.value()).then<void>(
      (_) => _inner.close().then<void>((_) {}, onError: (Object _) {}),
      onError: (Object _) {},
    );
  }

  static int _sizeOf(Object frame) => switch (frame) {
    final String text => text.length,
    final List<int> bytes => bytes.length,
    _ => 0,
  };
}

/// The stream `dart:io` pulls a [BufferedWebSocket]'s frames from. A
/// hand-written subscription, because it must be able to end while the
/// socket has it paused (a `StreamController` would hold the done event
/// until the peer read again, which a stalled peer never does).
final class _Feed extends Stream<Object> {
  _Feed(this._socket);

  final BufferedWebSocket _socket;
  void Function(Object data)? _onData;
  void Function()? _onDone;
  int _pauses = 0;
  bool _listening = false;
  bool _ended = false;
  bool _ending = false;
  bool _flushing = false;
  bool _scheduled = false;
  Completer<void>? _drained;

  @override
  StreamSubscription<Object> listen(
    void Function(Object event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    if (_listening) {
      throw StateError('Stream has already been listened to.');
    }
    _listening = true;
    _onData = onData;
    _onDone = onDone;
    // Never deliver from inside listen().
    _schedule();
    return _FeedSubscription(this);
  }

  /// Hands frames to the socket while it accepts them.
  void flush() {
    if (!_listening || _flushing || _ended) {
      return;
    }
    _flushing = true;
    try {
      while (_pauses == 0 && !_ended) {
        final frame = _socket._take();
        if (frame == null) {
          break;
        }
        _onData?.call(frame);
      }
    } finally {
      _flushing = false;
    }
    if (_socket._queue.isEmpty) {
      final drained = _drained;
      _drained = null;
      drained?.complete();
      if (_ending) {
        _end();
      }
    }
  }

  /// Completes once every queued frame was handed to the socket.
  Future<void> drained() => _socket._queue.isEmpty || _ended
      ? Future<void>.value()
      : (_drained ??= Completer<void>()).future;

  /// Ends the stream once the queue is empty (now, when it is).
  void endWhenEmpty() {
    _ending = true;
    if (!_listening) {
      // dart:io has not listened yet: it will, and end at once.
      return;
    }
    if (_socket._queue.isEmpty) {
      _end();
    }
  }

  void _end() {
    if (_ended) {
      return;
    }
    _ended = true;
    final drained = _drained;
    _drained = null;
    drained?.complete();
    _onDone?.call();
  }

  void _schedule() {
    if (_scheduled) {
      return;
    }
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (_ending && _socket._queue.isEmpty) {
        _end();
      } else {
        flush();
      }
    });
  }

  void pause() => _pauses++;

  void resume() {
    if (_pauses > 0 && --_pauses == 0) {
      // Not from inside the socket's own resume.
      _schedule();
    }
  }

  bool get isPaused => _pauses > 0;

  Future<void> cancel() {
    if (!_ended) {
      _ended = true;
      _socket._detached();
      final drained = _drained;
      _drained = null;
      drained?.complete();
    }
    return Future<void>.value();
  }
}

/// The subscription `dart:io` holds on a [_Feed].
final class _FeedSubscription implements StreamSubscription<Object> {
  _FeedSubscription(this._feed);

  final _Feed _feed;

  @override
  void onData(void Function(Object data)? handleData) =>
      _feed._onData = handleData;

  @override
  void onError(Function? handleError) {
    // The feed never fails.
  }

  @override
  void onDone(void Function()? handleDone) => _feed._onDone = handleDone;

  @override
  void pause([Future<void>? resumeSignal]) {
    _feed.pause();
    if (resumeSignal != null) {
      unawaited(resumeSignal.whenComplete(resume));
    }
  }

  @override
  void resume() => _feed.resume();

  @override
  bool get isPaused => _feed.isPaused;

  @override
  Future<void> cancel() => _feed.cancel();

  @override
  Future<E> asFuture<E>([E? futureValue]) {
    final done = Completer<E>();
    _feed._onDone = () => done.complete(futureValue as E);
    return done.future;
  }
}
