import 'dart:convert';

import 'package:daravel/daravel.dart';

/// API routes mounted under `/api`.
void apiRoutes(Router router) {
  // HTTP REST endpoint demonstrating backend-to-WebSocket push
  // Useful for external notifications, background jobs, webhooks, etc.
  router.post('/chat/{room}/broadcast', (Request request) async {
    final rawRoom = request.param<String>('room');
    final room = rawRoom.trim().isEmpty ? 'general' : rawRoom.trim();
    final data = await request.all();

    final messageRaw = data['message'] as String?;
    final messageText = (messageRaw != null && messageRaw.trim().isNotEmpty)
        ? messageRaw.trim()
        : 'Notification from server';
    final senderRaw = data['sender'] as String?;
    final senderName = (senderRaw != null && senderRaw.trim().isNotEmpty)
        ? senderRaw.trim()
        : 'Backend REST API';

    final payload = jsonEncode(<String, Object?>{
      'type': 'broadcast',
      'room': room,
      'sender': senderName,
      'text': messageText,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    });

    // Publish to the coordinator, delivering to all worker isolates
    final deliveredCount = await Broadcast.publish('chat.$room', payload);

    return Response.json(<String, Object?>{
      'status': 'published',
      'channel': 'chat.$room',
      'delivered_to_isolates': deliveredCount,
      'payload': jsonDecode(payload),
    });
  });
}
