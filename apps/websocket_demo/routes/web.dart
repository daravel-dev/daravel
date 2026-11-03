import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';

import '../resources/views/chat_page.dart';

/// Web and WebSocket routes mounted at the root path (`/`).
void webRoutes(Router router) {
  // 1. Interactive HTML Client
  router.get('/', (Request request) {
    final app = Config.section<AppConfig>();
    return Response.html(
      chatPage(
        appName: app.name,
        environment: app.env,
        frameworkVersion: daravelVersion,
      ),
    );
  });

  // 2. Simple Echo WebSocket route
  // Demonstrates basic 1-to-1 duplex WebSocket communication
  router.ws('/ws/echo', (WebSocket socket, Request request) async {
    try {
      await for (final message in socket) {
        socket.add('Echo: $message');
      }
    } catch (_) {
      // Socket stream finished or closed abruptly
    } finally {
      try {
        await socket.close(WebSocketStatus.normalClosure);
      } catch (_) {}
    }
  });

  // 3. Multi-Isolate Real-Time Chat Room WebSocket route
  // Demonstrates route parameter binding and inter-isolate broadcasting via Broadcast.pipe
  router.ws('/ws/chat/{room}', (WebSocket socket, Request request) async {
    final rawRoom = request.param<String>('room');
    final room = rawRoom.trim().isEmpty ? 'general' : rawRoom.trim();
    final channel = 'chat.$room';

    // Send welcome handshake message to this client
    socket.add(
      jsonEncode(<String, Object?>{
        'type': 'system',
        'text': 'Welcome to room #$room! Connected via Daravel WebSocket.',
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      }),
    );

    // Pipe the broadcast channel to this socket.
    // When messages are sent by the client, publish them across isolates!
    await Broadcast.pipe(
      socket,
      <String>[channel],
      onMessage: (Object? message) async {
        if (message == null) return;
        if (message is String && message.trim().isEmpty) return;
        try {
          await Broadcast.publish(channel, message);
        } catch (_) {
          // Socket dropped or coordinator unavailable during publish
        }
      },
    );
  });
}
