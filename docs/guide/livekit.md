# LiveKit

[LiveKit](https://livekit.io) carries the video, audio and screen sharing
of a virtual classroom or a meeting over WebRTC; the browser or the Flutter
app connects to it with `livekit_client`. `daravel_livekit` is the server
side: it signs the access tokens those clients connect with, manages rooms
and participants through LiveKit's room service, and verifies LiveKit's
webhooks. It speaks the same protocol as LiveKit's PHP SDK
(`agence104/livekit-server-sdk`), so a Laravel and a Daravel application
can share one LiveKit server.

```bash
dart pub add daravel_livekit
```

```dart
// bootstrap/app.dart
import 'package:daravel_livekit/daravel_livekit.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withLivekit()
    // ...
    .create();
```

```dotenv
LIVEKIT_URL=https://livekit.example.com   # or LIVEKIT_HOST, as older apps name it
LIVEKIT_API_KEY=...
LIVEKIT_API_SECRET=...                    # or LIVEKIT_SECRET_KEY
```

Boot warns while both are missing, and fails when the key is set but the
secret is not: an empty secret would sign tokens LiveKit refuses and verify
webhooks anyone could forge. `LivekitToken` and `LivekitWebhookReceiver`
throw `StateError` on an empty secret for the same reason.

## Tokens

A client joins a room with a token the server signs:

```dart
router.post('/classes/{id}/join', (request) async {
  final user = (await Auth.user<User>())!;
  final token = await Livekit.token(
    identity: user.uuid,
    name: user.name,
    ttl: const Duration(hours: 2),
    video: VideoGrant(roomJoin: true, room: 'class-7a', roomAdmin: user.isTeacher),
  ).toJwt();
  return {'token': token, 'url': Livekit.config.url};
});
```

`VideoGrant` has LiveKit's fields (`roomJoin`, `room`, `roomAdmin`,
`canPublish`, `canSubscribe`, `canPublishData`, `canPublishSources`,
`hidden`, ...); a field left out is not sent, so LiveKit's default applies.
Joining needs an identity, and a token lives 4 hours unless `ttl` says
otherwise. `LivekitToken.verify(jwt, apiKey: ..., apiSecret: ...)` reads
one back.

## Rooms and participants

```dart
final rooms = Livekit.rooms;

if ((await rooms.listRooms(['class-7a'])).isEmpty) {
  await rooms.createRoom('class-7a', maxParticipants: 40, metadata: '{"subject":"math"}');
}
final present = await rooms.listParticipants('class-7a');
await rooms.updateParticipant('class-7a', 'student-9', metadata: '{"hand":true}');
await rooms.removeParticipant('class-7a', 'student-9');
await rooms.sendData('class-7a', utf8.encode('{"type":"quiz"}'), topic: 'lk-chat');
await rooms.deleteRoom('class-7a');
```

Each call is signed with a 10-minute token carrying only the grant it needs
(`roomCreate`, `roomList`, or `roomAdmin` on that room), as LiveKit's SDKs
do. A refusal is a `LivekitException` with Twirp's `code` (`not_found`,
`permission_denied`) and the HTTP status. A call whose connection failed
before anything was sent (refused, reset), or that LiveKit answered 502
or 503 (a node restarting), is sent again up to `retries` (2) more
times after `retryDelay` (200 ms) doubled each time with jitter; a timeout
or any other answer is final, since the call may have been processed and
`sendData` twice is two messages. The client sends through the
application's HTTP client, so `Http.fake()` stubs it in tests.

## Webhooks

LiveKit posts events (`room_started`, `room_finished`,
`participant_joined`, `participant_left`, `track_published`,
`egress_ended`, ...) signed with the API secret:

```dart
router.post('/livekit/webhook', (request) async {
  final event = await Livekit.webhook(request);
  if (event.event == 'room_finished') {
    await Meeting.query().where('livekit_room_name', event.room!.name).update({'status': 'FINISHED'});
  }
  return Response.noContent();
});
```

`Livekit.webhook` checks the `Authorization` token (signature, expiry,
issued under the API key) and that its `sha256` claim is the base64
SHA-256 of the exact body, as LiveKit's SDKs do, and, beyond them, that
the event's `created_at` is within `maxAge` (five minutes, 30 s of skew
either way), since a captured webhook could otherwise be sent again for
as long as its token lives, and that the event's id was not received
already (each id is kept in the application's cache for that window);
anything else is a 401 `LivekitWebhookException`. There is no switch to skip that check: a
webhook route that accepts unsigned events lets anyone mark a meeting as
finished.

## With Laravel

`bench/interop/livekit.sh` runs LiveKit's PHP SDK and Daravel against each
other: each verifies the other's tokens, and each accepts the other's
signed webhooks and refuses a tampered body. The tests run against a
LiveKit server in development mode, which accepts Daravel's join tokens.
Egress and ingress, and SIP grants, are not covered yet.
