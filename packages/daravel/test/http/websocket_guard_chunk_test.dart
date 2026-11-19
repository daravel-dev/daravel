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

  Future<(_FakeSocket, WebSocket)> connect() async {
    final guard = WebSocketGuard(
      const WebSocketGuardLimits(
        maxMessageBytes: 16 << 20,
        maxBufferedBytes: 16 << 20,
        closeGrace: Duration(seconds: 30),
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
}

/// A socket whose bytes a test hands over in chunks of its choosing.
final class _FakeSocket extends Stream<Uint8List> implements Socket {
  final StreamController<Uint8List> _in = StreamController<Uint8List>();
  final Completer<void> _done = Completer<void>();

  bool get paused => _in.isPaused;

  void feed(Uint8List chunk) => _in.add(chunk);

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
  void add(List<int> data) {}

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) async {
    await stream.drain<void>();
  }

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() async {
    destroy();
  }

  @override
  void destroy() {
    if (!_done.isCompleted) {
      _done.complete();
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

  final _FakeSocket socket = _FakeSocket();

  @override
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
