import 'package:daravel/daravel.dart';
import 'package:daravel_livekit/daravel_livekit.dart';

import '../models/meeting.dart';
import '../models/user.dart';

/// What a client needs to join a meeting's LiveKit room.
final class RoomPass {
  const RoomPass({
    required this.url,
    required this.room,
    required this.token,
    required this.expiresAt,
    required this.admin,
  });

  final String url;
  final String room;
  final String token;
  final DateTime expiresAt;
  final bool admin;

  Map<String, Object?> toJson() => {
    'url': url,
    'room': room,
    'token': token,
    'expires_at': expiresAt.toUtc().toIso8601String(),
    'admin': admin,
  };
}

/// Opens a meeting's room on LiveKit and signs a token for one participant.
abstract final class ClassroomRoom {
  /// The room of [meeting], created on LiveKit with its participant limit
  /// (CreateRoom returns the room when it exists, so the first of many
  /// students joining at once does not need to win a race), and a token
  /// for [user] valid until [Meeting.grace] after the end. The teacher is
  /// the room's admin (mute, remove); students join and publish.
  static Future<RoomPass> pass(Meeting meeting, User user) async {
    final teacher = (await meeting.classroom()).taughtBy(user);
    await Livekit.rooms.createRoom(
      meeting.roomName,
      maxParticipants: meeting.maxParticipants,
      emptyTimeout: const Duration(minutes: 10),
    );
    final expiresAt = meeting.endsAt.add(Meeting.grace);
    final token = await Livekit.token(
      identity: 'user-${user.id}',
      name: user.name,
      metadata: '{"role":"${teacher ? 'teacher' : 'student'}"}',
      ttl: expiresAt.difference(Clock.now()),
      video: VideoGrant(
        roomJoin: true,
        room: meeting.roomName,
        roomAdmin: teacher,
        canPublish: true,
        canSubscribe: true,
        canPublishData: true,
      ),
    ).toJwt();
    return RoomPass(
      url: Livekit.config.url,
      room: meeting.roomName,
      token: token,
      expiresAt: expiresAt,
      admin: teacher,
    );
  }
}
