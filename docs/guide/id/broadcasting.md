<!-- source: broadcasting.md sha256:042211fceeff -->
# Broadcasting

Daravel berbicara dengan protokol Pusher, seperti Laravel Reverb, di port
yang sama dengan HTTP-nya. Laravel Echo terhubung ke sana tanpa perubahan,
Laravel bisa mem-broadcast lewat Daravel, dan Daravel bisa mem-broadcast
lewat Reverb (atau Pusher Channels). Satu `.env` dipakai kedua framework:
key-nya sama dengan Laravel.

## Melayani Echo

```dotenv
REVERB_APP_ID=my-app
REVERB_APP_KEY=my-key            # publik: Echo terhubung dengannya
REVERB_APP_SECRET=my-secret      # menandatangani otorisasi channel dan request API
```

```dart
Application.configure(basePath: '.')
    .withBroadcasting(
      channels: (channels) {
        channels.channel('App.Models.User.{id}',
            (user, p) => '${user.authIdentifier}' == p['id']);
        channels.channel('orders.{orderId}', (user, p) async =>
            (await Order.find(int.parse(p['orderId']!)))?['user_id'] ==
            user.authIdentifier);
        channels.channel('chat.{room}',
            (user, p) => {'id': user.authIdentifier, 'name': (user as User).name});
      },
    )
```

`channels` adalah `routes/channels.php` milik Laravel: pola tanpa prefix
`private-` atau `presence-`, `{placeholder}` yang cocok sampai titik
berikutnya, dan callback yang mengembalikan `false` untuk menolak, `true`
untuk channel private, atau data publik user untuk channel presence.
Route-nya:

| Route | Kegunaan |
| :-- | :-- |
| `GET /app/{key}` | Endpoint WebSocket tempat Echo terhubung (protokol Pusher 7) |
| `POST /broadcasting/auth` | Menandatangani channel private dan presence, di belakang `authMiddleware` (`['auth']` secara default) |
| `POST /apps/{id}/events`, `/apps/{id}/batch_events` | Penerbitan event, untuk Laravel dan client HTTP Pusher lain |
| `GET /apps/{id}/channels`, `/channels/{channel}`, `/channels/{channel}/users` | Informasi channel |

Front end-nya sama dengan Laravel:

```js
import Echo from 'laravel-echo';
import Pusher from 'pusher-js';

window.Echo = new Echo({
  broadcaster: 'reverb',
  key: import.meta.env.VITE_REVERB_APP_KEY,
  wsHost: 'api.example.com',
  wsPort: 443,
  forceTLS: true,
  enabledTransports: ['ws', 'wss'],
  authEndpoint: 'https://api.example.com/broadcasting/auth',
  auth: { headers: { Authorization: `Bearer ${token}` } },
  Pusher,
});

Echo.private(`orders.${orderId}`).listen('OrderShipped', (e) => { /* ... */ });
Echo.join(`chat.${room}`).here(users).joining(user).leaving(user);
Echo.private(`App.Models.User.${userId}`).notification((n) => { /* ... */ });
```

Koneksi, langganan, dan anggota presence dibagi oleh semua worker isolate
melalui coordinator, sehingga `APP_ISOLATES=4` berperilaku seperti satu
server. Beberapa server (mesin, atau proses di belakang load balancer)
berbagi semua itu melalui database, seperti Reverb berbagi melalui Redis;
lihat [Beberapa server](#beberapa-server).

## Mem-broadcast event

```dart
final class OrderShipped with ShouldBroadcast {
  OrderShipped(this.order);
  final Order order;

  @override
  List<String> broadcastOn() => ['private-orders.${order.id}'];

  @override
  Map<String, Object?> broadcastWith() => {'id': order.id, 'status': 'shipped'};
}

await Event.dispatch(OrderShipped(order));            // listener, lalu broadcast
await Broadcast.event(OrderShipped(order).toOthers()); // broadcast()->toOthers() dari Laravel
await Broadcast.send('price.updated', ['prices'], {'sku': 'A1', 'price': 12});
```

- Nama channel memakai prefix Pusher, seperti yang ditulis `PrivateChannel`
  dan `PresenceChannel` di Laravel: `private-orders.7`, `presence-chat.1`.
- Nama event adalah `App\Events\<Class>` kecuali `broadcastAs` menentukan
  lain; itulah yang diharapkan `.listen('OrderShipped')` di Echo. Nama
  kustom didengarkan dengan titik di depan (`.listen('.shipped')`).
- Dart tidak punya reflection, jadi `broadcastWith` menentukan apa yang
  dikirim (Laravel mengirim property publik secara default).
  `broadcastWhen` bisa melewatinya.
- `toOthers()` membaca header `X-Socket-ID` dari Echo di request saat ini
  dan tidak mengirim ke tab browser itu.
- Broadcast terjadi saat event di-dispatch, bukan lewat queue
  (`ShouldBroadcastNow` di Laravel).
- Channel notifikasi `broadcast` mengirim `BroadcastNotificationCreated`
  dari Laravel di `private-App.Models.User.1`, yang diterima
  `.notification()` di Echo ([Mail dan notifikasi](mail.md#broadcast)).

## Tujuan event

`BROADCAST_CONNECTION` memilih tujuannya:

| Nilai | Event dikirim ke |
| :-- | :-- |
| `daravel` (default) | koneksi di server ini, di semua isolate |
| `reverb` | Laravel Reverb (atau Daravel lain) di `REVERB_HOST`, `REVERB_PORT`, `REVERB_SCHEME`, melalui API HTTP-nya |
| `pusher` | Pusher Channels: `PUSHER_APP_ID`, `PUSHER_APP_KEY`, `PUSHER_APP_SECRET`, `PUSHER_APP_CLUSTER` (atau `PUSHER_HOST`) |
| `log` | log |
| `null` | tidak ke mana pun |

Laravel mem-broadcast lewat Daravel dengan cara yang sama:
`BROADCAST_CONNECTION=reverb` dengan `REVERB_HOST` menunjuk ke server
Daravel, dan app id, key, serta secret yang sama. Daravel mengecek tanda
tangan request seperti Pusher, dan juga menolak request yang timestamp-nya
meleset lebih dari sepuluh menit, sehingga request yang tersadap tidak bisa
diputar ulang (Reverb tidak mengecek waktunya).

## Channel cache dan channel terenkripsi

Channel yang namanya diawali `cache-` (atau `private-cache-`,
`presence-cache-`) menyimpan event terakhirnya selama 30 menit, seperti
Pusher Channels: client yang berlangganan belakangan langsung menerimanya
setelah `subscription_succeeded`, atau `pusher:cache_miss` bila belum ada.

```dart
await Broadcast.send('price.updated', ['cache-prices'], {'sku': 'A1', 'price': 13});
```

```js
Echo.channel('cache-prices').listen('.price.updated', (e) => { /* harga terakhir */ });
```

Channel `private-encrypted-` dienkripsi end-to-end, seperti di Pusher:
isi `REVERB_ENCRYPTION_MASTER_KEY_BASE64` (32 byte acak dalam base64:
`openssl rand -base64 32`) dan dengarkan dengan `Echo.encryptedPrivate`.
Kunci setiap channel diturunkan dari master key, `/broadcasting/auth`
memberikannya kepada client yang diizinkan channel itu, dan event disegel
dengan `secretbox` dari libsodium sebelum keluar dari aplikasi, sehingga
server WebSocket hanya meneruskan ciphertext. Client tidak bisa mengirim
whisper di channel ini.

```dart
await Broadcast.send('secret', ['private-encrypted-orders.7'], {'code': '4821'});
```

```js
Echo.encryptedPrivate('orders.7').listen('.secret', (e) => { /* sudah didekripsi */ });
```

Kunci yang sama berlaku untuk `BROADCAST_CONNECTION=reverb` atau `pusher`:
Laravel (dengan `encryption_master_key_base64`) dan Daravel mengenkripsi
dengan cara yang sama.

## Beberapa server

```dotenv
REVERB_SCALING_ENABLED=true
# REVERB_SCALING_CONNECTION=pgsql   # koneksi selain koneksi default
```

Tambahkan `CreateBroadcastingTables()` ke `bootstrap/migrations.dart` lalu
jalankan `dartisan migrate`. Setelah itu setiap server menulis frame yang
dikirimnya ke `broadcast_messages`, dan setiap server membaca frame dari
server lain lalu meneruskannya ke client-nya sendiri, sehingga event yang
diterbitkan di satu server (lewat API HTTP, `Broadcast.send`, atau whisper)
sampai ke client yang terhubung ke server mana pun. Di PostgreSQL server
saling membangunkan dengan `NOTIFY`; di MySQL dan MariaDB server membaca
setiap `REVERB_SCALING_POLL` (`100ms`) selama ada frame yang mengalir, dan
melambat sampai sekali per detik saat tidak ada, sehingga isolate worker
yang menganggur tidak melakukan query sepuluh kali per detik masing-masing.

Anggota presence juga dibagi, berbeda dengan Reverb yang `here`-nya hanya
memuat anggota di server yang sama: `here`, `member_added` (sekali per
user, di server mana pun tab user itu berada), serta `channels`, `channel`,
dan `users` dari API HTTP menjawab untuk seluruh cluster, begitu pula event
terakhir sebuah channel cache. Setiap isolate worker di setiap server
mengirim heartbeat setiap sepuluh detik; anggota dari isolate yang diam
selama 30 detik (karena crash) tidak dihitung lagi dan dihapus semenit
kemudian, dan worker yang dijalankan ulang dengan nama yang sama
menghapusnya saat mulai. Koneksi yang subscribe lagi ke channel yang sudah
diikutinya tetap dihitung satu anggota.

Dengan [daravel_redis](redis.md), `REVERB_SCALING_DRIVER=redis` membagi
hal yang sama lewat Redis: frame lewat Pub/Sub, anggota dan channel cache
di Redis, sehingga database tidak menanggungnya sama sekali.

Beri setiap server `REVERB_SERVER_ID` yang tetap bila nama host dan id
proses tidak cukup membedakannya. Load balancer tidak perlu sticky session:
client tetap di server yang dijangkau WebSocket-nya.

## Origin dan batas

| Variabel | Default | Kegunaan |
| :-- | :-- | :-- |
| `REVERB_ALLOWED_ORIGINS` | `*` | Pola host yang boleh terhubung, dipisah koma (`app.example.com,*.example.com`) |
| `REVERB_APP_ACTIVITY_TIMEOUT` | `30` | Detik tanpa aktivitas sebelum client mengirim ping; server juga mengirim ping |
| `REVERB_APP_MAX_MESSAGE_SIZE` | `10000` | Ukuran pesan terbesar yang boleh dikirim client, dalam byte |
| `REVERB_MAX_BUFFERED_BYTES` | `1048576` | Berapa banyak yang boleh menunggu dikirim ke satu client; lewat dari itu client ditutup dengan `4100` (over capacity) dan tersambung ulang setelah backoff |
| `REVERB_APP_MAX_CHANNELS_PER_CONNECTION` | `100` | Jumlah channel yang boleh diikuti satu koneksi sekaligus (`0`: tanpa batas); lewat dari itu `pusher:error` `4300`, koneksi tetap terbuka |
| `REVERB_APP_CLIENT_EVENTS_PER_SECOND` | `10` | Client event yang boleh dikirim satu koneksi per detik, seperti Pusher Channels (`0`: tanpa batas); lewat dari itu event dibuang dengan `pusher:error` `4301` |
| `REVERB_APP_VALIDATE_CHANNEL_NAMES` | `true` | Nama channel mengikuti aturan Pusher: paling banyak 164 karakter dari `A-Z a-z 0-9 _ - = @ , . ;`; nama lain mendapat `pusher:error` `4300` |
| `REVERB_APP_MAX_CONNECTIONS` | tidak ada | Jumlah koneksi yang boleh dibuka aplikasi di server ini, semua worker isolate dihitung (`max_connections` di Reverb); lewat dari itu `pusher:error` `4004` "Application is over connection quota" dan koneksi ditutup sebelum `connection_established` |
| `REVERB_APP_RATE_LIMITING_ENABLED` | `false` | Membatasi laju pesan tiap koneksi, seperti `rate_limiting` di Reverb: setiap pesan dihitung, termasuk `pusher:ping`; lewat dari batas `pusher:error` `4301` |
| `REVERB_APP_RATE_LIMIT_MAX_ATTEMPTS` | `60` | Jumlah pesan yang diizinkan per jendela waktu |
| `REVERB_APP_RATE_LIMIT_DECAY_SECONDS` | `60` | Panjang jendela waktu, dihitung dari pesan pertama koneksi di jendela itu |
| `REVERB_APP_RATE_LIMIT_TERMINATE` | `false` | Menutup koneksi yang melewati batas (kode `4301`), bukan hanya menolak pesannya |
| `REVERB_DRAIN_SPREAD` | `2s` | Saat shutdown, koneksi Pusher ditutup (`1001`) pada saat acak dalam rentang ini (paling lama sebesar shutdown timeout), sehingga client-nya tidak tersambung ulang bersamaan |
| `BROADCAST_AFTER_COMMIT` | `true` | Broadcast di dalam transaksi database dikirim saat transaksi commit dan dibuang saat rollback (`Broadcast.send(..., afterCommit: false)` langsung mengirim) |

Client event (`client-*`, `whisper` di Echo) hanya diteruskan di channel
private dan presence yang sudah diikuti pengirimnya, seperti yang
disyaratkan Pusher Channels.

Saat sebuah worker isolate crash, anggota presence yang semua koneksinya
ada di isolate itu diumumkan ke subscriber lain dengan
`pusher_internal:member_removed` (`leaving` di Echo), seolah-olah mereka
keluar. Stream server-sent event mendapat `retry:` acak 1 sampai 5 detik
sebelum berakhir saat shutdown, dengan alasan yang sama seperti drain
spread. `/metrics` menghitung penolakan di `reverb_rejected_total{reason}`
(`connection_quota`, `rate_limit`, `client_event_rate`, `channel_limit`) dan
`reverb_rate_limited_total{app}`; client yang lambat ada di
`realtime_slow_clients_total`. `Channels.private('orders.7')`,
`Channels.presence(...)` dan `Channels.encrypted(...)` menuliskan prefix-nya.

Saat coordinator tidak bisa menjawab (kelebihan beban, atau penyimpanan
scaling mati) ketika client subscribe atau keluar dari channel, client
mendapat `pusher:error` dan koneksinya ditutup dengan `4100` (over
capacity), sehingga Echo tersambung ulang setelah backoff; channel yang
tertinggal karena `leave` gagal dicoba sekali lagi dan dicatat di log, dan
tidak pernah membuat channel lain dari koneksi itu tetap ter-subscribe.
Relay yang gagal dijalankan (Redis mati) dijalankan lagi oleh client
berikutnya.

## Kapasitas

`bench/interop/connections.sh` membuka koneksi Echo idle ke build AOT,
semuanya berlangganan satu channel, lalu mengukur waktu satu event sampai
ke semuanya. Dengan 10 000 koneksi:

| | Memori (RSS) | Satu event ke semua |
| :-- | --: | --: |
| Daravel, 1 isolate | 11 MB idle, 189 MB terisi (sekitar 18 KB per koneksi) | 0,62 s |
| Daravel, 4 isolate | 12 MB idle, 188 MB terisi | 0,43 s |
| `dart:io` saja (server `WebSocket` polos) | 7 MB idle, 98 MB terisi (sekitar 9 KB per koneksi) | 0,63 s |
| Laravel Reverb 1.12 | 54 MB idle, sekitar 21 KB per koneksi (1 000 koneksi) | |

Sekitar separuh biaya tiap koneksi adalah WebSocket dari `dart:io` itu
sendiri. Reverb tanpa `ext-uv` atau `ext-event` berhenti di sekitar 1 000
koneksi (`stream_select` dari PHP). WebSocket berjalan tanpa
permessage-deflate, seperti di Reverb: mengompresi setiap frame untuk
setiap koneksi membuat event yang sama butuh 7,9 s.

## Diverifikasi dengan client sungguhan

`bench/interop/run.sh` (Linux dan Docker) mengecek semua ini terhadap
perangkat lunak yang harus didukungnya: `laravel-echo` dan `pusher-js` dari
npm terhadap Daravel (publik, private, `toOthers`, whisper, presence,
notifikasi, channel cache dan terenkripsi, otorisasi yang ditolak), dua server Daravel yang berbagi satu database, Laravel 12 yang mem-broadcast lewat
Daravel dengan `pusher/pusher-php-server`, dan Daravel yang mem-broadcast
lewat Laravel Reverb, dengan satu atau empat worker isolate
(`ISOLATES=4`).

## Tingkat bawah: channel milik Daravel sendiri

`Broadcast.publish`, `subscribe`, dan `pipe` memindahkan pesan antar-worker
isolate tanpa protokol Pusher, untuk route WebSocket atau SSE Anda sendiri
([Respons](responses.md#broadcast-ke-semua-isolate)).

## Padanan Laravel

Bagian lain dari Laravel yang ikut didukung, beserta API yang bisa dicari di pub.dev.

| Laravel | Daravel | API | Catatan |
| :-- | :-- | :-- | :-- |
| `php artisan reverb:start (Laravel Reverb)` | `.withBroadcasting(...) with REVERB_APP_ID / _KEY / _SECRET` | `PusherServer` | Protokol Pusher di port HTTP; Laravel Echo dan pusher-js tersambung tanpa perubahan. |
| `Echo.channel('cache-prices') (Pusher cache channels)` | `Broadcast.send(..., ['cache-prices'], ...)` | `PusherServer.isCacheChannel` | Event terakhir disimpan 30 menit untuk subscriber baru. |
| `Echo.encryptedPrivate('orders.7') with encryption_master_key_base64` | `REVERB_ENCRYPTION_MASTER_KEY_BASE64` | `BroadcastConfig.encryptionMasterKey` | Channel `private-encrypted-`, disegel dengan secretbox dari libsodium. |
| `REVERB_SCALING_ENABLED=true (Reverb with Redis)` | `REVERB_SCALING_ENABLED=true (the database)` | `DatabaseBroadcastRelay` | Frame, anggota presence, dan cache channel menjangkau semua server. |
