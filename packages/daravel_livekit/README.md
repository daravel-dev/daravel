<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_livekit

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_livekit/README.id.md)

[LiveKit](https://livekit.io)'s server SDK for [Daravel](https://pub.dev/packages/daravel):
the access tokens WebRTC clients join rooms with, the room service (rooms,
participants, data messages) and verified webhooks. It speaks the protocol
of LiveKit's PHP SDK, so a Laravel and a Daravel application share one
LiveKit server.

```bash
dart pub add daravel_livekit
```

```dart
Application.configure(basePath: '.').withLivekit() // LIVEKIT_URL, LIVEKIT_API_KEY, LIVEKIT_API_SECRET

final token = await Livekit.token(
  identity: user.uuid,
  name: user.name,
  video: VideoGrant(roomJoin: true, room: 'class-7a', roomAdmin: isTeacher),
).toJwt();

await Livekit.rooms.createRoom('class-7a', maxParticipants: 40);

router.post('/livekit/webhook', (request) async {
  final event = await Livekit.webhook(request); // 401 unless LiveKit signed it
  // event.event == 'room_finished', event.room?.name, ...
  return Response.noContent();
});
```

- Tokens with LiveKit's claims and grants; each room service call signed
  with a short token carrying only the grant it needs.
- Webhooks checked as LiveKit's SDKs check them (signature, expiry, issuer,
  the body's SHA-256), with no switch to skip it.
- Tested against a LiveKit server and against LiveKit's PHP SDK.

Documentation: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/livekit.md>.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC; LiveKit is a trademark of LiveKit, Inc. Daravel is
an independent project, not affiliated with or endorsed by any of them.
