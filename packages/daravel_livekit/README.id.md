<!-- source: README.md sha256:5a8e55214e58 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_livekit

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_livekit/README.md) · Bahasa Indonesia

SDK server [LiveKit](https://livekit.io) untuk [Daravel](https://pub.dev/packages/daravel):
access token yang dipakai client WebRTC untuk bergabung ke room, room
service (room, participant, pesan data), dan webhook yang terverifikasi.
Paket ini berbicara protokol yang sama dengan SDK PHP LiveKit, sehingga
aplikasi Laravel dan Daravel berbagi satu server LiveKit.

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
  final event = await Livekit.webhook(request); // 401 kecuali ditandatangani LiveKit
  // event.event == 'room_finished', event.room?.name, ...
  return Response.noContent();
});
```

- Token dengan klaim dan grant dari LiveKit; setiap pemanggilan room
  service ditandatangani dengan token singkat yang hanya membawa grant yang
  dibutuhkannya.
- Webhook dicek seperti SDK LiveKit mengeceknya (signature, masa berlaku,
  penerbit, SHA-256 dari body), tanpa opsi untuk melewatinya.
- Diuji terhadap server LiveKit dan terhadap SDK PHP LiveKit.

Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/livekit.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC; LiveKit adalah merek dagang LiveKit, Inc. Daravel
adalah proyek independen, tidak berafiliasi dengan dan tidak didukung oleh
pihak mana pun di atas.
