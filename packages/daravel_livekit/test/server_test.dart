@Tags(['integration'])
library;

import 'dart:io';
import 'dart:math';

import 'package:daravel_livekit/daravel_livekit.dart';
import 'package:test/test.dart';

/// Against a LiveKit server in development mode (keys `devkey` / `secret`):
/// `DARAVEL_TEST_LIVEKIT=http://127.0.0.1:7880`, e.g. from
/// `docker run -p 7880:7880 livekit/livekit-server --dev --bind 0.0.0.0`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_LIVEKIT'];
  if (url == null || url.isEmpty) {
    test(
      'LiveKit server (skipped: DARAVEL_TEST_LIVEKIT not set)',
      () {},
      skip: true,
    );
    return;
  }
  final rooms = RoomServiceClient(url, apiKey: 'devkey', apiSecret: 'secret');
  final name = 'daravel-test-${Random().nextInt(1 << 32)}';
  tearDownAll(() async {
    try {
      await rooms.deleteRoom(name);
    } on LivekitException {
      // Gone already.
    }
  });

  test('rooms: create, list, metadata, participants, data, delete', () async {
    final created = await rooms.createRoom(
      name,
      maxParticipants: 30,
      emptyTimeout: const Duration(minutes: 5),
      metadata: '{"flavor":"test"}',
    );
    expect(created.name, name);
    expect(created.sid, startsWith('RM_'));
    expect(created.maxParticipants, 30);
    expect(created.emptyTimeout, const Duration(minutes: 5));
    expect(created.metadata, '{"flavor":"test"}');
    expect(created.createdAt, isNotNull);

    final listed = await rooms.listRooms([name]);
    expect(listed.map((r) => r.sid), [created.sid]);
    expect(await rooms.listRooms(['no-such-room-${created.sid}']), isEmpty);

    final updated = await rooms.updateRoomMetadata(name, '{"flavor":"x"}');
    expect(updated.metadata, '{"flavor":"x"}');

    expect(await rooms.listParticipants(name), isEmpty);
    await rooms.sendData(name, [104, 105], topic: 'lk-chat');

    await rooms.deleteRoom(name);
    expect(await rooms.listRooms([name]), isEmpty);
  });

  test('the server refuses as Twirp errors', () async {
    await rooms.createRoom(name);
    await expectLater(
      rooms.getParticipant(name, 'nobody'),
      throwsA(isA<LivekitException>().having((e) => e.status, 'status', 404)),
    );
    final wrong = RoomServiceClient(url, apiKey: 'devkey', apiSecret: 'nope');
    await expectLater(
      wrong.listRooms(),
      throwsA(isA<LivekitException>().having((e) => e.status, 'status', 401)),
    );
  });

  test('the server accepts our join tokens, and refuses forged ones', () async {
    Future<int> validate(String secret) async {
      final token = await LivekitToken(
        apiKey: 'devkey',
        apiSecret: secret,
        identity: 'teacher-1',
        name: 'Teacher',
        video: VideoGrant(roomJoin: true, room: name, roomAdmin: true),
      ).toJwt();
      // What the server checks when a client connects with the token.
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('$url/rtc/validate?access_token=$token'),
        );
        final response = await request.close();
        await response.drain<void>();
        return response.statusCode;
      } finally {
        client.close();
      }
    }

    expect(await validate('secret'), 200);
    expect(await validate('forged'), 401);
  });
}
