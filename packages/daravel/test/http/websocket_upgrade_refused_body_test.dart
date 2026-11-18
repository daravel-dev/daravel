import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

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

  Future<({String response, bool closed})> send(String headers) async {
    final socket = await Socket.connect('127.0.0.1', engine.port!);
    addTearDown(socket.destroy);
    socket.write('GET /ws HTTP/1.1\r\nHost: localhost\r\n$headers\r\n');
    await socket.flush();
    final bytes = <int>[];
    var closed = false;
    try {
      await socket.timeout(const Duration(seconds: 3)).forEach(bytes.addAll);
      closed = true;
    } on TimeoutException {
      // Reported by the expectation below.
    }
    return (response: latin1.decode(bytes), closed: closed);
  }

  Future<void> expectTerminated(int status) async {
    final deadline = DateTime.now().add(const Duration(seconds: 3));
    while (counting.terminated.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(counting.handled, 1);
    expect(counting.terminated, [status]);
    expect(counting.deferred, 1);
    expect(engine.inFlight, 0);
  }

  Future<void> expectBadRequest(String headers) async {
    final result = await send(headers);
    expect(result.response, startsWith('HTTP/1.1 400'));
    expect(result.response.toLowerCase(), contains('connection: close'));
    expect(
      result.response.toLowerCase(),
      isNot(contains('upgrade: websocket')),
    );
    expect(result.closed, isTrue);
    await expectTerminated(400);
  }

  for (final (bodyName, bodyHeader) in [
    ('without a declared body', ''),
    ('with a declared body', 'Content-Length: 1000000\r\n'),
  ]) {
    for (final (name, header) in [
      ('key', 'Sec-WebSocket-Key: value\r\n'),
      ('version', 'Sec-WebSocket-Version: 13\r\n'),
    ]) {
      test(
        'a handshake with a repeated $name field is refused $bodyName',
        () async {
          await expectBadRequest('$header$handshake$bodyHeader');
        },
      );
    }

    test('an upgrade failure before takeover is refused $bodyName', () async {
      ServerEngine.webSocketUpgradeOverride = (
        request, {
        compression = CompressionOptions.compressionDefault,
        maxPayloadLength,
      }) async => throw const WebSocketException('refused');
      await expectBadRequest('$handshake$bodyHeader');
    });
  }

  test(
    'an upgrade failure after takeover closes and terminates once',
    () async {
      ServerEngine.webSocketUpgradeOverride =
          (
            request, {
            compression = CompressionOptions.compressionDefault,
            maxPayloadLength,
          }) async {
            await request.response.detachSocket(writeHeaders: false);
            throw const WebSocketException('failed after takeover');
          };
      final result = await send(handshake);
      expect(result.response, isEmpty);
      expect(result.closed, isTrue);
      await expectTerminated(400);
    },
  );
}
