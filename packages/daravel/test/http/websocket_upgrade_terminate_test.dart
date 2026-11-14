import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Counts what the kernel does with each request: handled once, and
/// terminated once with the response sent, its deferred work run.
final class _Counting implements TerminableMiddleware {
  int handled = 0;
  final List<int> terminated = [];
  int deferred = 0;

  @override
  Future<Response> handle(Request request, Next next) {
    handled++;
    request.defer(() => deferred++);
    return next(request);
  }

  @override
  void terminate(Request request, Response response) =>
      terminated.add(response.status);
}

/// A WebSocket request answered without a socket (426, or 400 for a
/// handshake that does not read as one or an upgrade that fails, before or
/// after it took the connection over) is terminated once, like any other
/// request: its terminable middleware and deferred work run.
void main() {
  late Application app;
  late ServerEngine engine;
  late _Counting counting;

  setUp(() async {
    counting = _Counting();
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withMiddleware((m) => m.use([counting]))
        .withRouting(
          web: (router) => router.ws('/ws', (socket, _) {
            socket.listen(socket.add);
          }),
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
    ServerEngine.webSocketUpgradeOverride = null;
    await engine.stop();
    await app.shutdown();
  });

  const key = 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n';
  const handshake =
      'Upgrade: websocket\r\nConnection: Upgrade\r\n$key'
      'Sec-WebSocket-Version: 13\r\n';

  /// Sends a GET of /ws with [headers]; the status line that came back
  /// (empty when none did) once the server closed or 3 s passed.
  Future<String> send(String headers) async {
    final socket = await Socket.connect('127.0.0.1', engine.port!);
    addTearDown(socket.destroy);
    socket.write('GET /ws HTTP/1.1\r\nHost: localhost\r\n$headers\r\n');
    await socket.flush();
    final bytes = <int>[];
    await socket
        .timeout(const Duration(seconds: 3))
        .forEach(bytes.addAll)
        .then<void>((_) {}, onError: (Object _) {});
    return latin1.decode(bytes).split('\r\n').first;
  }

  /// Waits until the request was terminated (it runs after the answer).
  Future<void> terminated() async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (counting.terminated.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // And nothing more after a moment.
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }

  void expectOnce(int status) {
    expect(counting.handled, 1);
    expect(counting.terminated, [status]);
    expect(counting.deferred, 1);
  }

  test('426: not a WebSocket request', () async {
    expect(await send(''), startsWith('HTTP/1.1 426'));
    await terminated();
    expectOnce(426);
  });

  test('400: a handshake that does not read as one', () async {
    expect(
      await send('Upgrade: websocket\r\n$handshake'),
      startsWith('HTTP/1.1 400'),
    );
    await terminated();
    expectOnce(400);
  });

  test('400: an upgrade that fails before it took the connection', () async {
    ServerEngine.webSocketUpgradeOverride = (
      request, {
      compression = CompressionOptions.compressionDefault,
      maxPayloadLength,
    }) async => throw const WebSocketException('refused');
    expect(await send(handshake), startsWith('HTTP/1.1 400'));
    await terminated();
    expectOnce(400);
  });

  test('an upgrade that fails after it took the connection: nothing '
      'answered, the connection closed, terminated with 400', () async {
    ServerEngine.webSocketUpgradeOverride =
        (
          request, {
          compression = CompressionOptions.compressionDefault,
          maxPayloadLength,
        }) async {
          await request.response.detachSocket(writeHeaders: false);
          throw const WebSocketException('failed after the takeover');
        };
    expect(await send(handshake), isEmpty);
    await terminated();
    expectOnce(400);
  });

  test('an upgrade that succeeds is terminated once, when the session '
      'ends', () async {
    final socket = await WebSocket.connect('ws://127.0.0.1:${engine.port}/ws');
    socket.add('hi');
    expect(await socket.first, 'hi');
    await socket.close();
    await terminated();
    expectOnce(101);
  });
}
