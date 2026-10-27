<!-- source: redis.md sha256:ab7dc0400c11 -->
# Redis

Di satu server, Daravel tidak membutuhkan Redis: isolate coordinator
menyimpan cache, lock, dan rate limit untuk semua worker isolate di memori,
dan queue database bersifat ACID. `daravel_redis` ditujukan untuk beberapa
server, saat state itu harus dibagi dan database menjadi bottleneck.

| Setup Anda | Pakai |
| :-- | :-- |
| Satu VPS atau satu container | Default-nya (`CACHE_STORE=process`, queue database). Jangan tambahkan Redis |
| Beberapa server, trafik kecil, sudah ada PostgreSQL atau MySQL | `CACHE_STORE=database`, queue database, `REVERB_SCALING_ENABLED` lewat database. Tetap tanpa Redis |
| Beberapa server dengan latensi ketat, rate limit yang ketat, banyak job atau WebSocket lintas server, atau aplikasi Laravel yang sudah memakai Redis | `daravel_redis` |

Paket ini bekerja dengan Redis 6.2 ke atas dan dengan Valkey, dan berbicara
protokolnya sendiri (tanpa library native).

## Instalasi

```bash
dart pub add daravel_redis
```

```dart
// bootstrap/app.dart
import 'package:daravel_redis/daravel_redis.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withRedis()
    // ...
    .create();
```

`withRedis()` mendaftarkan semua yang dijelaskan di bawah; tidak ada yang
terhubung sampai sesuatu memakai Redis, jadi tidak ada biayanya selama
`.env` tidak memintanya.

## Memilihnya di `.env`

```dotenv
REDIS_HOST=10.0.0.15
REDIS_PASSWORD=secret
# atau REDIS_URL=rediss://user:secret@redis.example.com:6380/0

CACHE_STORE=redis          # cache, lock, denylist JWT
CACHE_LIMITER=redis        # rate limit, masing-masing satu round trip
QUEUE_CONNECTION=redis     # job diambil begitu di-push

REVERB_SCALING_ENABLED=true
REVERB_SCALING_DRIVER=redis  # server broadcasting berbagi client Echo
```

| Pengaturan | Yang dikerjakan Redis |
| :-- | :-- |
| `CACHE_STORE=redis` | `Cache` dan `Cache.lock` di semua server. Logout (`Auth.jwtGuard().invalidate()`) juga sampai ke semua server, karena denylist JWT disimpan di store default |
| `CACHE_LIMITER=redis` | Setiap percobaan adalah satu skrip Lua; percobaan yang diblokir tidak dihitung |
| `QUEUE_CONNECTION=redis` | Job di Redis; worker yang menganggur menunggu dengan `BLPOP` dan langsung menjalankan job yang di-push, tidak menunggu `--sleep`. Lock unique job serta `queue:restart` / `queue:pause` juga masuk ke Redis (`QUEUE_UNIQUE_LOCK_STORE=redis`) |
| `REVERB_SCALING_DRIVER=redis` | Frame antarserver lewat Pub/Sub; anggota presence, API channels, dan channel cache di Redis ([Broadcasting](broadcasting.md#beberapa-server)) |

Cache memakai koneksi `cache` (`REDIS_CACHE_DB`, default 1), sehingga
`dartisan cache:clear` hanya menghapus key milik cache (`SCAN` dan `UNLINK`
pada prefix-nya, tidak pernah `FLUSHDB`) dan tidak pernah menyentuh job
yang sedang antre.

## Konfigurasi

| Variabel | Default | Kegunaan |
| :-- | :-- | :-- |
| `REDIS_URL` | tidak ada | `redis://` atau `rediss://` (TLS), `user:password@host:port/database`; menggantikan variabel di bawah |
| `REDIS_HOST`, `REDIS_PORT` | `127.0.0.1`, `6379` | Server |
| `REDIS_USERNAME`, `REDIS_PASSWORD` | tidak ada | User ACL (Redis 6+) dan password |
| `REDIS_DB`, `REDIS_CACHE_DB` | `0`, `1` | Database koneksi `default` dan `cache`, seperti di Laravel |
| `REDIS_PREFIX` | `<app>-database-` | Ditaruh di depan setiap key, default Laravel 12 |
| `REDIS_CACHE_LOCK_CONNECTION` | `default` | Tempat lock cache disimpan, seperti `lock_connection` dari Laravel |
| `REDIS_TLS` | `false` | TLS tanpa `rediss://`; boot memberi peringatan bila host publik dijangkau tanpanya |
| `REDIS_COMMAND_TIMEOUT`, `REDIS_CONNECT_TIMEOUT` | `1s`, `2s` | Perintah yang timeout menutup koneksinya, yang dibuka lagi pada perintah berikutnya |
| `REDIS_MAX_IN_FLIGHT` | `1024` | Perintah yang menunggu balasan di satu koneksi; selebihnya langsung ditolak |
| `QUEUE_REDIS_NAMESPACE` | `daravel` | Ruang key untuk queue, terpisah dari `queues:` milik Laravel |

`/up/ready` mendapat pengecekan `redis` (`PING`). Password tidak pernah
muncul di log maupun error.

## Facade `Redis`

```dart
await Redis.set('greeting', 'halo', ttl: const Duration(minutes: 5));
final greeting = await Redis.get('greeting');
await Redis.command(['HSET', 'user:7', 'name', 'Ana']);

final script = RedisScript("return redis.call('INCRBY', KEYS[1], ARGV[1])");
await Redis.eval(script, keys: ['visits'], args: [1]);

await Redis.publish('orders', '{"id":7}');
Redis.subscribe(['orders']).messages.listen((message) { /* ... */ });
```

Setiap isolate memegang satu koneksi, dan perintah yang dikirim tanpa saling
menunggu berbagi round trip-nya (pipelining). Perintah blocking dan
subscription mendapat koneksi sendiri; subscription akan subscribe ulang
setelah koneksinya terputus.

## Jaminan

- **Pembacaan cache fail-open:** saat Redis mati, pembacaan dianggap miss
  dan aplikasi menjawab dari sumber aslinya. Penulisan melempar exception.
- **Lock fail-closed** dan dimiliki pemiliknya, seperti `RedisLock` dari
  Laravel. Ini lock satu instance, bukan Redlock: failover dengan replikasi
  asinkron bisa menghilangkannya. Untuk pekerjaan yang tidak boleh berjalan
  dua kali (penagihan), gunakan lock di database.
- **Job berjalan minimal sekali:** job yang di-reserve worker yang mati akan
  berjalan lagi setelah `QUEUE_RETRY_AFTER`. Handler sebaiknya idempoten,
  seperti di Laravel. Payload job tetap persis seperti yang di-push.
- **Pub/Sub paling banyak sekali:** event yang terbit saat sebuah server
  sedang menyambung ulang tidak sampai ke client di server itu.

## Bersama Laravel di Redis yang sama

| | |
| :-- | :-- |
| Lock | Dibagi bila keduanya memakai `REDIS_PREFIX` dan `CACHE_PREFIX` yang sama: key yang sama di koneksi yang sama, `SET NX PX`, dan skrip pelepasan yang sama. `dartisan adopt` memberi Daravel prefix cache sendiri, jadi samakan `CACHE_PREFIX` dengan milik Laravel untuk berbagi lock |
| Angka di cache | Dibagi: disimpan sebagai digit biasa |
| Nilai cache lainnya | Daravel menyimpan JSON, Laravel memakai `serialize()` dari PHP: masing-masing tidak bisa membaca milik yang lain |
| Queue | Dipisah (namespace `daravel:`): worker Laravel tidak bisa menjalankan job Daravel, begitu pula sebaliknya |

`bench/interop/redis.sh` mengecek semua ini terhadap Laravel 12 dengan
predis: lock yang diambil salah satunya ditolak bagi yang lain dengan
pemilik yang sama, dan angka di cache bertambah dari kedua sisi.

## Belum tersedia

Redis Sentinel dan Cluster, cache dua tingkat dengan `CLIENT TRACKING`,
engine queue Streams, dan serializer yang kompatibel dengan PHP sudah
direncanakan. Sampai saat itu, arahkan `REDIS_URL` ke satu primary
(endpoint layanan terkelola juga bisa).
