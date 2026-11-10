<!-- source: README.md sha256:cf3229378e9e -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_reverb_client

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_reverb_client/README.md) · Bahasa Indonesia

Klien protokol Pusher 7 mengikuti Laravel Echo, dalam Dart murni: berjalan
di VM, di Flutter (Android, iOS, desktop), dan di web, serta berbicara
dengan **Laravel Reverb**, **Daravel** (`withBroadcasting()`,
`daravel_reverb`), dan Pusher. Paket ini tidak bergantung pada server
Daravel, sehingga aplikasi Flutter juga bisa memakainya terhadap backend
Laravel.

```dart
import 'package:daravel_reverb_client/daravel_reverb_client.dart';

final echo = Echo.reverb(
  key: 'app-key',
  host: 'wss://ws.example.com',
  auth: EchoAuth.bearer(
    () async => tokenStore.token,
    endpoint: 'https://api.example.com/broadcasting/auth',
  ),
);

echo.channel('news').listen('.announcement', (data) => print(data));
echo.private('orders.42').listen('OrderShipped', (data) => print(data['status']));
echo.join('classroom.7')
  ..here((members) => print(members))
  ..joining((member) => print('masuk: ${member['name']}'))
  ..leaving((member) => print('keluar: ${member['name']}'))
  ..whisper('typing', {'name': 'Teo'});
echo.encryptedPrivate('chat.9').listen('MessageSent', (data) => print(data));
echo.socketId; // header X-Socket-ID sebuah request (toOthers)
```

- **Nama event seperti yang ditulis Laravel Echo:** `listen('OrderShipped')` berarti `App\Events\OrderShipped` (`namespace:`); `listen('.order.shipped')` dipakai apa adanya.
- **Channel:** `channel`, `private`, `encryptedPrivate`, `join` (presence: `here`, `joining`, `leaving`, `members`); `whisper` dan `listenForWhisper`; `notification` (notifikasi broadcast Laravel); `listenToAll`, `stopListening`; `leave(name)`, `leaveChannel`, `leaveAll`. Channel cache (`cache-`) memberi subscriber yang datang belakangan event terakhir.
- **Otorisasi:** `EchoAuth.bearer` (token), `EchoAuth.endpoint` (header seperti cookie sesi), atau `EchoAuth.custom`. Channel yang ditolak memanggil callback `error` dan `onError`; tidak ada yang di-subscribe.
- **Channel terenkripsi** dibuka dengan `shared_secret` dari otorisasi (XSalsa20-Poly1305, seperti pusher-js). Whisper tidak didukung di sana.
- **Koneksi** mengirim ping setelah `activity_timeout` tanpa pesan, reconnect dengan backoff eksponensial dan jitter, lalu subscribe ulang. `pusher:error` 4000–4099 menghentikannya; 4200–4299 langsung reconnect. `connectionState`, `onConnectionStateChange`, `disconnect()`, dan `connect()`.
- **`path:`** untuk server dengan prefix (`REVERB_SERVER_PATH`).

Diuji terhadap server Pusher di dalam proses test, dan di `bench/interop` terhadap Daravel dan Laravel Reverb 1.x dengan skenario yang dilalui Laravel Echo dan pusher-js.

## Lisensi

MIT.
