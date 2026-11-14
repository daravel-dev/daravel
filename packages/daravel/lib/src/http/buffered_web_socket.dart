import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'websocket_stats.dart';

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
  int __bufferedBytes = 0;
  int get _bufferedBytes => __bufferedBytes;
  set _bufferedBytes(int value) {
    WebSocketGuardStats.queuedBy(value - __bufferedBytes);
    __bufferedBytes = value;
  }

  _Feed? _feed;
  Future<void>? _binding;
  bool _closing = false;
  bool _overflowed = false;
  Future<void>? _closed;

  /// Bytes (characters, for text frames) waiting to be sent.
  int get bufferedBytes => _bufferedBytes;

  /// Whether this connection was closed for reading too slowly.
  bool get isSlowClient => _overflowed;

  /// Whether the application listened to what the client sends (the
  /// handler, `Broadcast.pipe`); not the server's own [drainUnlistened].
  bool get isListened => _listened;
  bool _listened = false;

  /// Whether something reads what the client sends: the application, the
  /// server's [drainUnlistened], or this socket's own close, which waits
  /// for the client's answer. Until then the server holds what arrives.
  bool get isRead =>
      _listened || _drain != null || _drained || _closedUnlistened;

  /// Told when something starts reading ([isRead]): for the server, which
  /// then hands on what it held.
  void Function()? onReader;

  /// The server's subscription of [drainUnlistened], which a later [listen]
  /// takes over.
  StreamSubscription<dynamic>? _drain;

  /// [drainUnlistened] read the client's stream to its end.
  bool _drained = false;

  /// The socket was closed before anything listened (the server ended the
  /// session of a handler that had not read): a later [listen] gets the
  /// end only.
  bool _closedUnlistened = false;

  /// Reads what the client sends and drops it, for a handler that returned
  /// and has not listened: the client's close or its going away then ends
  /// the session. Whatever had arrived and was not read is dropped too. A
  /// [listen] after it takes this subscription over and gets what arrives
  /// from then on (its `cancelOnError` does not apply then); one after the
  /// stream ended gets just its end.
  void drainUnlistened() {
    if (_listened || _drain != null || _drained) {
      return;
    }
    _drain = _inner.listen(
      (_) {},
      // A stream error ends the session too, and `done` reports it.
      onError: (Object _) {},
      onDone: () {
        unawaited(_drain?.cancel());
        _drain = null;
        _drained = true;
        _peerClosed();
      },
    );
    onReader?.call();
  }

  @override
  StreamSubscription<dynamic> listen(
    void Function(dynamic event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    _listened = true;
    void done() {
      _peerClosed();
      onDone?.call();
    }

    if (_drained || _closedUnlistened) {
      // The server read the stream to its end already, or closed the
      // socket before anything listened: this listener gets the end,
      // nothing else, and never an error for a stream already read.
      return const Stream<dynamic>.empty().listen(
        null,
        onError: onError,
        onDone: done,
      );
    }
    final drain = _drain;
    if (drain != null) {
      // The server read for a handler that had not listened yet: this
      // listener takes its subscription over (a stream is listened once).
      _drain = null;
      return drain
        ..onData(onData)
        ..onError(onError ?? (Object _) {})
        ..onDone(done);
    }
    final subscription = _inner.listen(
      onData,
      onError: onError,
      onDone: done,
      cancelOnError: cancelOnError,
    );
    onReader?.call();
    return subscription;
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

  /// The code the session closed with, from the first of:
  /// 1. the client's close, as the server read it ([peerClosed]), even when
  ///    the connection was destroyed afterwards;
  /// 2. the code the server closed with after a violation (also through
  ///    [peerClosed], when the client sent no valid close of its own);
  /// 3. the socket's own, once it closed.
  @override
  int? get closeCode => _peerCloseCode ?? _inner.closeCode;

  /// The reason that goes with [closeCode], from the same source.
  @override
  String? get closeReason =>
      _peerCloseCode != null ? _peerCloseReason : _inner.closeReason;

  int? _peerCloseCode;
  String? _peerCloseReason;

  /// The client closed with [code] and [reason], as the server read it
  /// (its close frame read on this socket's behalf, or the connection
  /// destroyed after it): [closeCode] and [closeReason] report them, before
  /// whatever the end of the connection reports.
  void peerClosed(int code, String? reason) {
    _peerCloseCode = code;
    _peerCloseReason = reason;
  }

  /// The connection under this socket is gone (the server destroyed it):
  /// nothing queued can be sent, and [done] completes now instead of after
  /// a close grace.
  void abandon() {
    _closing = true;
    _queue.clear();
    _bufferedBytes = 0;
    if (!_gaveUp.isCompleted) {
      _gaveUp.complete();
    }
  }

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
    // A client that does not read will not read the close either: it gets
    // [slowClientGrace], not [closeGrace].
    _closed ??= _close(
      slowClientCode,
      slowClientReason,
      drop: true,
      grace: slowClientGrace,
    );
  }

  /// How long a slow client's close waits before the connection is given
  /// up.
  static const Duration slowClientGrace = Duration(seconds: 1);

  Future<void> _close(
    int? code,
    String? reason, {
    required bool drop,
    Duration grace = closeGrace,
  }) async {
    _closing = true;
    if (!_listened && _drain == null) {
      // Closed with nobody reading: a listen from now on gets the end
      // only.
      _closedUnlistened = true;
    }
    // Set before anything here waits on the client: unbinding waits for
    // the frame being written, which a client that stopped reading can
    // hold up. It covers the queued frames' own [closeGrace] (without
    // [drop]) and then the close's [grace]. A safeguard: no test fails
    // without it, as the guard destroys the socket of a client that stops
    // reading at its own limit first.
    final giveUp = Timer(drop ? grace : closeGrace + grace, () {
      if (!_gaveUp.isCompleted) {
        _gaveUp.complete();
      }
    });
    await Future.any<void>([_unbind(drop: drop), _gaveUp.future]);
    if (_gaveUp.isCompleted) {
      // Given up while unbinding: the sink is still bound, and [done] has
      // completed; nothing more to do here.
      return;
    }
    final closing = _inner
        .close(code, reason)
        .then<void>(
          (_) {},
          onError: (Object _) {
            // The socket is gone already; closing it again changes nothing.
          },
        );
    if (_closedUnlistened) {
      // The close waits for the client's answer: what was held goes on.
      onReader?.call();
    }
    await Future.any<void>([closing, _gaveUp.future]);
    giveUp.cancel();
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
