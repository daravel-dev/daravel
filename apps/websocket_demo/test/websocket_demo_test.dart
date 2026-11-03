import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import '../bootstrap/app.dart';

/// Helper queue to read WebSocket messages synchronously or sequentially.
final class _MessageQueue {
  _MessageQueue(Stream<dynamic> stream) {
    _subscription = stream.listen(
      (message) {
        if (_waiting.isNotEmpty) {
          _waiting.removeAt(0).complete(message);
        } else {
          _items.add(message);
        }
      },
      onDone: () {
        if (!_done.isCompleted) _done.complete();
      },
    );
  }

  late final StreamSubscription<dynamic> _subscription;
  final List<dynamic> _items = <dynamic>[];
  final List<Completer<dynamic>> _waiting = <Completer<dynamic>>[];
  final Completer<void> _done = Completer<void>();

  Future<void> get done => _done.future;

  Future<dynamic> get next {
    if (_items.isNotEmpty) {
      return Future<dynamic>.value(_items.removeAt(0));
    }
    final completer = Completer<dynamic>();
    _waiting.add(completer);
    return completer.future;
  }

  Future<void> cancel() => _subscription.cancel();
}

void main() {
  group('Daravel WebSocket Demo Application', () {
    late Application app;
    late ServerEngine engine;
    late HttpClient httpClient;

    setUp(() async {
      httpClient = HttpClient();
      app = createApp(
        basePath: Directory.systemTemp.path,
        env: const <String, String>{
          'APP_ENV': 'testing',
          'APP_NAME': 'Daravel WebSocket Demo',
          'APP_KEY': 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
        },
      );
      await app.boot();

      engine = ServerEngine(
        app,
        const ServeOptions(
          host: '127.0.0.1',
          port: 0,
          handleSignals: false,
          shutdownTimeout: Duration(seconds: 5),
        ),
        kernel: app.kernel,
        logger: Logger(minimumLevel: LogLevel.critical),
      );
      await engine.start();
    });

    tearDown(() async {
      httpClient.close(force: true);
      await engine.stop();
      await app.shutdown();
    });

    String wsUrl(String path) => 'ws://127.0.0.1:${engine.port}$path';
    Uri httpUrl(String path) =>
        Uri.parse('http://127.0.0.1:${engine.port}$path');

    test('GET / serves the interactive HTML client', () async {
      final request = await httpClient.getUrl(httpUrl('/'));
      final response = await request.close();
      final body = await response.transform(utf8.decoder).join();

      expect(response.statusCode, 200);
      expect(response.headers.contentType?.mimeType, 'text/html');
      expect(body, contains('Daravel WebSocket Demo'));
      expect(body, contains('/ws/chat/general'));
      expect(body, contains('POST /api/chat/'));
    });

    test(
      'Plain HTTP GET to WebSocket routes returns 426 Upgrade Required',
      () async {
        final echoReq = await httpClient.getUrl(httpUrl('/ws/echo'));
        final echoRes = await echoReq.close();
        expect(echoRes.statusCode, 426);
        expect(echoRes.headers.value('upgrade'), 'websocket');

        final chatReq = await httpClient.getUrl(httpUrl('/ws/chat/lobby'));
        final chatRes = await chatReq.close();
        expect(chatRes.statusCode, 426);
        expect(chatRes.headers.value('upgrade'), 'websocket');
      },
    );

    test('ws://.../ws/echo echoes sent messages back to client', () async {
      final socket = await WebSocket.connect(wsUrl('/ws/echo'));
      final queue = _MessageQueue(socket);
      addTearDown(() async {
        await queue.cancel();
        await socket.close();
      });

      socket.add('Ping Daravel');
      final reply = await queue.next.timeout(const Duration(seconds: 3));
      expect(reply, 'Echo: Ping Daravel');

      socket.add('Second message');
      final reply2 = await queue.next.timeout(const Duration(seconds: 3));
      expect(reply2, 'Echo: Second message');
    });

    test(
      'ws://.../ws/chat/{room} sends welcome message on connection',
      () async {
        final socket = await WebSocket.connect(wsUrl('/ws/chat/general'));
        final queue = _MessageQueue(socket);
        addTearDown(() async {
          await queue.cancel();
          await socket.close();
        });

        final first =
            await queue.next.timeout(const Duration(seconds: 3)) as String;
        final json = jsonDecode(first) as Map<String, Object?>;

        expect(json['type'], 'system');
        expect(json['text'], contains('Welcome to room #general'));
      },
    );

    test(
      'Broadcast delivers chat messages to multiple clients in the same room',
      () async {
        final clientA = await WebSocket.connect(wsUrl('/ws/chat/dev-room'));
        final queueA = _MessageQueue(clientA);

        final clientB = await WebSocket.connect(wsUrl('/ws/chat/dev-room'));
        final queueB = _MessageQueue(clientB);

        addTearDown(() async {
          await queueA.cancel();
          await queueB.cancel();
          await clientA.close();
          await clientB.close();
        });

        // Consume welcome messages
        await queueA.next.timeout(const Duration(seconds: 3));
        await queueB.next.timeout(const Duration(seconds: 3));

        // Client A sends a message
        final msg = jsonEncode(<String, Object?>{
          'sender': 'Alice',
          'text': 'Hello team!',
        });
        clientA.add(msg);

        // Both Client A and Client B receive the broadcast message
        final receivedA =
            await queueA.next.timeout(const Duration(seconds: 3)) as String;
        final receivedB =
            await queueB.next.timeout(const Duration(seconds: 3)) as String;

        expect(receivedA, msg);
        expect(receivedB, msg);
      },
    );

    test('Broadcast channels are isolated by room name', () async {
      final clientRoom1 = await WebSocket.connect(wsUrl('/ws/chat/room-one'));
      final queue1 = _MessageQueue(clientRoom1);

      final clientRoom2 = await WebSocket.connect(wsUrl('/ws/chat/room-two'));
      final queue2 = _MessageQueue(clientRoom2);

      addTearDown(() async {
        await queue1.cancel();
        await queue2.cancel();
        await clientRoom1.close();
        await clientRoom2.close();
      });

      // Consume welcomes
      await queue1.next.timeout(const Duration(seconds: 3));
      await queue2.next.timeout(const Duration(seconds: 3));

      // Client 1 sends message to room-one
      final msg = jsonEncode(<String, Object?>{
        'sender': 'Bob',
        'text': 'Secret room 1',
      });
      clientRoom1.add(msg);

      // Client 1 receives its own room's broadcast
      final received1 =
          await queue1.next.timeout(const Duration(seconds: 3)) as String;
      expect(received1, msg);

      // Client 2 in room-two does NOT receive it
      var receivedRoom2 = false;
      unawaited(queue2.next.then((_) => receivedRoom2 = true));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(receivedRoom2, isFalse);
    });

    test('HTTP POST /api/chat/{room}/broadcast pushes notification to WebSocket clients', () async {
      final socket = await WebSocket.connect(wsUrl('/ws/chat/announcements'));
      final queue = _MessageQueue(socket);
      addTearDown(() async {
        await queue.cancel();
        await socket.close();
      });

      // Consume welcome
      await queue.next.timeout(const Duration(seconds: 3));

      // External HTTP POST request to broadcast
      final postReq = await httpClient.postUrl(
        httpUrl('/api/chat/announcements/broadcast'),
      );
      postReq.headers.contentType = ContentType.json;
      postReq.write(
        jsonEncode(<String, Object?>{
          'sender': 'DeployBot',
          'message': 'Build v2.0 deployed successfully!',
        }),
      );
      final postRes = await postReq.close();
      final postBody = await postRes.transform(utf8.decoder).join();

      expect(postRes.statusCode, 200);
      final jsonResponse = jsonDecode(postBody) as Map<String, Object?>;
      expect(jsonResponse['status'], 'published');
      expect(jsonResponse['channel'], 'chat.announcements');

      // Connected WebSocket client receives the pushed broadcast
      final pushedMsg =
          await queue.next.timeout(const Duration(seconds: 3)) as String;
      final payload = jsonDecode(pushedMsg) as Map<String, Object?>;

      expect(payload['type'], 'broadcast');
      expect(payload['sender'], 'DeployBot');
      expect(payload['text'], 'Build v2.0 deployed successfully!');
      expect(payload['room'], 'announcements');
    });

    test('Client disconnect cleans up broadcast subscriptions', () async {
      final socket = await WebSocket.connect(wsUrl('/ws/chat/cleanup-room'));
      final queue = _MessageQueue(socket);
      await queue.next.timeout(const Duration(seconds: 3)); // consume welcome

      // Broadcast delivers to 1 client
      expect(await Broadcast.publish('chat.cleanup-room', 'probe 1'), 1);
      final received = await queue.next.timeout(const Duration(seconds: 3));
      expect(received, 'probe 1');

      // Close the client socket
      await queue.cancel();
      await socket.close();

      // Give event loop time to process socket drop and unregister channel
      for (var i = 0; i < 50; i++) {
        final count = await Broadcast.publish('chat.cleanup-room', 'probe 2');
        if (count == 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await Broadcast.publish('chat.cleanup-room', 'probe final'), 0);
    });

    test('ws://.../ws/echo closes cleanly without unhandled errors', () async {
      final socket = await WebSocket.connect(wsUrl('/ws/echo'));
      final queue = _MessageQueue(socket);
      socket.add('Hello');
      expect(
        await queue.next.timeout(const Duration(seconds: 3)),
        'Echo: Hello',
      );
      await socket.close(WebSocketStatus.normalClosure);
      await queue.done.timeout(const Duration(seconds: 3));
      await queue.cancel();
      expect(socket.closeCode, WebSocketStatus.normalClosure);
    });

    test(
      'Special and HTML characters are transported safely without corruption',
      () async {
        final client = await WebSocket.connect(wsUrl('/ws/chat/safe-html'));
        final queue = _MessageQueue(client);
        addTearDown(() async {
          await queue.cancel();
          await client.close();
        });
        await queue.next.timeout(const Duration(seconds: 3));

        final xssPayload = jsonEncode(<String, Object?>{
          'sender': '<script>alert("hacked")</script>',
          'text': '<img src="x" onerror="alert(1)">&foo="bar"',
        });
        client.add(xssPayload);

        final received =
            await queue.next.timeout(const Duration(seconds: 3)) as String;
        expect(received, xssPayload);
      },
    );

    test(
      'HTTP POST /api/chat/{room}/broadcast handles fallback defaults',
      () async {
        final postReq = await httpClient.postUrl(
          httpUrl('/api/chat/lobby/broadcast'),
        );
        postReq.headers.contentType = ContentType.json;
        postReq.write(jsonEncode(<String, Object?>{})); // empty payload
        final postRes = await postReq.close();
        final postBody = await postRes.transform(utf8.decoder).join();

        expect(postRes.statusCode, 200);
        final jsonResponse = jsonDecode(postBody) as Map<String, Object?>;
        expect(jsonResponse['status'], 'published');
        final payload = jsonResponse['payload'] as Map<String, Object?>;
        expect(payload['text'], 'Notification from server');
        expect(payload['sender'], 'Backend REST API');
        expect(payload['room'], 'lobby');
      },
    );
  });
}
