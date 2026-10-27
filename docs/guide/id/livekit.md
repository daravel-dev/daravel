<!-- source: livekit.md sha256:acb92185c828 -->
# LiveKit

[LiveKit](https://livekit.io) membawa video, audio, dan berbagi layar
sebuah kelas virtual atau rapat lewat WebRTC; browser atau aplikasi Flutter
terhubung ke sana dengan `livekit_client`. `daravel_livekit` adalah sisi
server-nya: menandatangani access token yang dipakai client untuk terhubung,
mengelola room dan participant lewat room service LiveKit, serta
memverifikasi webhook dari LiveKit. Paket ini berbicara protokol yang sama
dengan SDK PHP LiveKit (`agence104/livekit-server-sdk`), sehingga aplikasi
Laravel dan Daravel bisa berbagi satu server LiveKit.

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
LIVEKIT_URL=https://livekit.example.com   # atau LIVEKIT_HOST, nama lama di aplikasi lama
LIVEKIT_API_KEY=...
LIVEKIT_API_SECRET=...                    # atau LIVEKIT_SECRET_KEY
```

Boot memberi peringatan selama keduanya belum diisi, dan gagal bila key
diisi tetapi secret tidak: secret kosong akan menandatangani token yang
ditolak LiveKit dan memverifikasi webhook yang bisa dipalsukan siapa pun.
`LivekitToken` dan `LivekitWebhookReceiver` melempar `StateError` untuk
secret kosong dengan alasan yang sama.

## Token

Client bergabung ke room dengan token yang ditandatangani server:

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

`VideoGrant` memakai field dari LiveKit (`roomJoin`, `room`, `roomAdmin`,
`canPublish`, `canSubscribe`, `canPublishData`, `canPublishSources`,
`hidden`, ...); field yang tidak diisi tidak dikirim, sehingga default
LiveKit yang berlaku. Bergabung ke room membutuhkan identity, dan token
berlaku 4 jam kecuali `ttl` menentukan lain.
`LivekitToken.verify(jwt, apiKey: ..., apiSecret: ...)` membacanya kembali.

## Room dan participant

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

Setiap pemanggilan ditandatangani dengan token 10 menit yang hanya membawa
grant yang dibutuhkannya (`roomCreate`, `roomList`, atau `roomAdmin` pada
room itu), seperti SDK LiveKit. Penolakan berupa `LivekitException` dengan
`code` dari Twirp (`not_found`, `permission_denied`) dan status HTTP-nya.
Client mengirim lewat HTTP client aplikasi, sehingga `Http.fake()` bisa
menggantikannya di test.

## Webhook

LiveKit mengirim event (`room_started`, `room_finished`,
`participant_joined`, `participant_left`, `track_published`,
`egress_ended`, ...) yang ditandatangani dengan API secret:

```dart
router.post('/livekit/webhook', (request) async {
  final event = await Livekit.webhook(request);
  if (event.event == 'room_finished') {
    await Meeting.query().where('livekit_room_name', event.room!.name).update({'status': 'FINISHED'});
  }
  return Response.noContent();
});
```

`Livekit.webhook` mengecek token di `Authorization` (signature, masa
berlaku, diterbitkan atas API key) dan bahwa klaim `sha256`-nya adalah
SHA-256 base64 dari body yang persis sama, seperti SDK LiveKit; selain itu
dijawab 401 dengan `LivekitWebhookException`. Tidak ada opsi untuk melewati
pengecekan itu: route webhook yang menerima event tanpa tanda tangan
membuat siapa pun bisa menandai sebuah rapat sudah selesai.

## Bersama Laravel

`bench/interop/livekit.sh` menjalankan SDK PHP LiveKit dan Daravel saling
berhadapan: masing-masing memverifikasi token dari sisi lain, serta
menerima webhook bertanda tangan dari sisi lain dan menolak body yang
diubah. Test berjalan terhadap server LiveKit dalam mode development, yang
menerima join token dari Daravel. Egress dan ingress, serta grant SIP,
belum dicakup.
