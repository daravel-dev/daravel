import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/src/http/websocket_guard.dart';
import 'package:daravel/src/http/websocket_stats.dart';
import 'package:test/test.dart';

import 'support/raw_ws_client.dart';

/// The guard fed chunks of a chosen size, as a system with a large receive
/// buffer hands them over (Linux, macOS): a real socket on Windows reads at
/// most 64 KiB at a time, so a violation is never in the middle of a large
/// chunk there.
void main() {
  setUp(WebSocketGuardStats.reset);

  int readSinceDone() => WebSocketGuardStats.toJson()['readWhileEnding'] ?? 0;
  const bound = 4 << 20;

  Future<(_FakeSocket, WebSocket)> connect({
    Duration closeGrace = const Duration(seconds: 30),
  }) async {
    final guard = WebSocketGuard(
      WebSocketGuardLimits(
        maxMessageBytes: 16 << 20,
        maxBufferedBytes: 16 << 20,
        closeGrace: closeGrace,
      ),
    );
    final request = _FakeRequest();
    final webSocket = await WebSocketTransformer.upgrade(guard.wrap(request));
    guard.attach(webSocket);
    webSocket.listen((_) {}, onError: (Object _) {});
    return (request.socket, webSocket);
  }

  Uint8List frames(int n) {
    final frame = RawWsClient.frame(0x2, Uint8List(64 << 10));
    final builder = BytesBuilder(copy: false);
    for (var i = 0; i < n; i++) {
      builder.add(frame);
    }
    return builder.takeBytes();
  }

  test('what follows a violation in the same chunk is counted', () async {
    final (socket, webSocket) = await connect();
    final violation = RawWsClient.frame(0x3, const []);
    final rest = frames(16);
    socket.feed(Uint8List.fromList([...violation, ...rest]));
    await pumpEventQueue();
    expect(readSinceDone(), rest.length);
    socket.feed(frames(1));
    await pumpEventQueue();
    expect(readSinceDone(), rest.length + frames(1).length);
    socket.destroy();
    await webSocket.close().timeout(
      const Duration(seconds: 1),
      onTimeout: () {},
    );
  });

  test('a violation followed by more than the bound in one chunk stops '
      'reading at once', () async {
    final (socket, webSocket) = await connect();
    final violation = RawWsClient.frame(0x3, const []);
    socket.feed(Uint8List.fromList([...violation, ...frames(80)]));
    await pumpEventQueue();
    expect(readSinceDone(), bound);
    expect(socket.paused, isTrue, reason: 'reading stopped at the bound');
    socket.destroy();
    await webSocket.close().timeout(
      const Duration(seconds: 1),
      onTimeout: () {},
    );
  });

  // What the session wrote is handed to the system (Socket.close and done
  // complete) before the client read it: destroying the socket then drops
  // it (seen on Windows with a small receive buffer). Only time bounds it:
  // past the bound reading stops and the grace ends the socket.
  const grace = Duration(milliseconds: 300);

  /// A session that wrote 768 KiB and closed; with [clientCloses], the
  /// client's CLOSE came first, sent before it read anything of ours.
  Future<_FakeSocket> sessionOver({required bool clientCloses}) async {
    final (socket, webSocket) = await connect(closeGrace: grace);
    webSocket.add(Uint8List(768 << 10));
    if (clientCloses) {
      socket.feed(RawWsClient.frame(0x8, const [0x03, 0xE8]));
      await pumpEventQueue();
    }
    await webSocket
        .close(1000, 'bye')
        .timeout(const Duration(seconds: 2), onTimeout: () {});
    await pumpEventQueue();
    expect(socket.closed, isTrue, reason: 'the session wrote and closed');
    expect(socket.written, greaterThan(768 << 10));
    return socket;
  }

  Uint8List pieces(int total) => Uint8List(total);

  for (final (name, clientCloses, send) in [
    ('past the bound', false, () => frames(80)),
    ('exactly the bound', false, () => pieces(bound)),
    ('past the bound, both sides closing at once', true, () => frames(80)),
  ]) {
    test('the session over, a client that sends $name before it reads: '
        'reading stops, the socket lives until the grace, then goes', () async {
      // ignore: close_sinks (the grace destroys it, as asserted below)
      final socket = await sessionOver(clientCloses: clientCloses);
      final before = readSinceDone();
      final bytes = send();
      for (var at = 0; at < bytes.length; at += 64 << 10) {
        socket.feed(
          Uint8List.sublistView(
            bytes,
            at,
            at + (64 << 10) > bytes.length ? bytes.length : at + (64 << 10),
          ),
        );
      }
      await pumpEventQueue();
      expect(readSinceDone(), lessThanOrEqualTo(bound));
      expect(readSinceDone() - before, greaterThan(0));
      expect(
        socket.destroyed,
        isFalse,
        reason:
            'what was written still reaches a client that reads within '
            'the grace',
      );
      expect(socket.paused, isTrue, reason: 'nothing more is read');
      final read = readSinceDone();
      await Future<void>.delayed(grace * 2);
      expect(readSinceDone(), read, reason: 'the count is not reset');
      expect(
        socket.destroyed,
        isTrue,
        reason:
            'a client that never reads does not hold the socket past the '
            'grace',
      );
    });
  }

  test('the session over, a client that never reads and sends under the '
      'bound: read on and dropped, the grace from the session end ends '
      'the socket', () async {
    // The grace the session's end starts (WebSocketGuard._dispose) bounds
    // every socket after its session, under the bound too; what the client
    // has not read by then is lost (a known limit, as for a slow client).
    int graces() => WebSocketGuardStats.toJson()['graces']!;
    final gracesBefore = graces();
    // ignore: close_sinks (the grace destroys it, as asserted below)
    final socket = await sessionOver(clientCloses: false);
    expect(graces() - gracesBefore, 1, reason: 'the session end started one');
    socket.feed(frames(16));
    await pumpEventQueue();
    expect(socket.destroyed, isFalse);
    expect(socket.paused, isFalse, reason: 'read on, dropped');
    await Future<void>.delayed(grace * 2);
    expect(socket.destroyed, isTrue);
    expect(graces() - gracesBefore, 0);
  });
}

/// A socket whose bytes a test hands over in chunks of its choosing.
final class _FakeSocket extends Stream<Uint8List> implements Socket {
  final StreamController<Uint8List> _in = StreamController<Uint8List>();
  final Completer<void> _done = Completer<void>();

  bool get paused => _in.isPaused;

  /// Bytes handed over for writing; [closed] once the writing side was
  /// closed, [destroyed] once destroyed.
  int written = 0;
  bool closed = false;
  bool destroyed = false;

  void feed(Uint8List chunk) {
    if (!_in.isClosed) {
      _in.add(chunk);
    }
  }

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

  @override
  void add(List<int> data) => written += data.length;

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      written += data.length;
    }
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    // As a socket's close: the writing side only; reading goes on.
    closed = true;
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  @override
  void destroy() {
    destroyed = true;
    if (!_done.isCompleted) {
      _done.complete();
    }
    if (!_in.isClosed) {
      unawaited(_in.close());
    }
  }

  @override
  Future<void> get done => _done.future;

  @override
  bool setOption(SocketOption option, bool enabled) => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeHeaders implements HttpHeaders {
  final Map<String, List<String>> _values = {};

  @override
  List<String>? operator [](String name) => _values[name.toLowerCase()];

  @override
  String? value(String name) => this[name]?.single;

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) =>
      _values.putIfAbsent(name.toLowerCase(), () => []).add('$value');

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      _values[name.toLowerCase()] = ['$value'];

  @override
  int contentLength = -1;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeResponse implements HttpResponse {
  _FakeResponse(this._socket);

  final _FakeSocket _socket;

  @override
  int statusCode = 200;

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  Future<Socket> detachSocket({bool writeHeaders = true}) async => _socket;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeRequest extends Stream<Uint8List> implements HttpRequest {
  _FakeRequest() {
    headers
      ..set('connection', 'Upgrade')
      ..set('upgrade', 'websocket')
      ..set('sec-websocket-version', '13')
      ..set('sec-websocket-key', 'dGhlIHNhbXBsZSBub25jZQ==');
  }

  // ignore: close_sinks (each test destroys it)
  final _FakeSocket socket = _FakeSocket();

  @override
  // ignore: close_sinks (a fake: it holds nothing to close)
  late final HttpResponse response = _FakeResponse(socket);

  @override
  final HttpHeaders headers = _FakeHeaders();

  @override
  String get method => 'GET';

  @override
  Uri get uri => Uri.parse('/ws');

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => const Stream<Uint8List>.empty().listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
