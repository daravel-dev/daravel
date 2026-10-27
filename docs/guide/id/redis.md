<!-- source: redis.md sha256:5c036070ead3 -->
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

Paket ini bekerja dengan Redis 6.2 ke atas dan dengan Valkey, di satu
server, di belakang Sentinel, maupun sebagai Redis Cluster, dan berbicara
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
| `CACHE_STORE=tiered` | Sama, dengan memori setiap isolate di depan Redis ([di bawah](#cache-di-setiap-isolate)) |
| `CACHE_LIMITER=redis` | Setiap percobaan adalah satu skrip Lua; percobaan yang diblokir tidak dihitung |
| `QUEUE_CONNECTION=redis` | Job di Redis; worker yang menganggur menunggu dengan `BLPOP` dan langsung menjalankan job yang di-push, tidak menunggu `--sleep`. Lock unique job serta `queue:restart` / `queue:pause` juga masuk ke Redis (`QUEUE_UNIQUE_LOCK_STORE=redis`) |
| `REVERB_SCALING_DRIVER=redis` | Frame antarserver lewat Pub/Sub; anggota presence, API channels, dan channel cache di Redis ([Broadcasting](broadcasting.md#beberapa-server)) |

Cache memakai koneksi `cache` (`REDIS_CACHE_DB`, default 1), sehingga
`dartisan cache:clear` hanya menghapus key cache itu sendiri (`SCAN` dan
`UNLINK` pada prefix-nya, tidak pernah `FLUSHDB`) dan tidak pernah
menyentuh job yang sedang antre.

## Konfigurasi

| Variabel | Default | Kegunaan |
| :-- | :-- | :-- |
| `REDIS_URL` | tidak ada | `redis://` atau `rediss://` (TLS), `user:password@host:port/database`; `redis+sentinel://` dan `redis+cluster://` mendaftar beberapa host ([di bawah](#sentinel-dan-cluster)). Menggantikan variabel di bawah |
| `REDIS_HOST`, `REDIS_PORT` | `127.0.0.1`, `6379` | Server |
| `REDIS_USERNAME`, `REDIS_PASSWORD` | tidak ada | User ACL (Redis 6+) dan password |
| `REDIS_DB`, `REDIS_CACHE_DB` | `0`, `1` | Database koneksi `default` dan `cache`, seperti di Laravel |
| `REDIS_PREFIX` | `<app>-database-` | Ditaruh di depan setiap key, default Laravel 12 |
| `REDIS_CACHE_LOCK_CONNECTION` | `default` | Tempat lock cache disimpan, seperti `lock_connection` dari Laravel |
| `REDIS_TLS` | `false` | TLS tanpa `rediss://`; boot memberi peringatan bila host publik dijangkau tanpanya |
| `REDIS_COMMAND_TIMEOUT`, `REDIS_CONNECT_TIMEOUT` | `1s`, `2s` | Perintah yang timeout menutup koneksinya, yang dibuka lagi pada perintah berikutnya |
| `REDIS_MAX_IN_FLIGHT` | `1024` | Perintah yang menunggu balasan di satu koneksi; selebihnya langsung ditolak |
| `REDIS_MODE` | `standalone` | `sentinel` atau `cluster`, bersama `REDIS_NODES` |
| `REDIS_NODES` | `REDIS_HOST:REDIS_PORT` | `host:port,host:port`: para Sentinel, atau node cluster tempat memulai |
| `REDIS_SENTINEL_SERVICE` | `mymaster` | Nama master di Sentinel |
| `REDIS_SENTINEL_USERNAME`, `REDIS_SENTINEL_PASSWORD` | tidak ada | Kredensial Sentinel itu sendiri |
| `REDIS_SERIALIZER` | `json` | `php` menulis nilai cache seperti `serialize()` dari Laravel; keduanya selalu bisa dibaca |
| `REDIS_TIERED_MAX_KEYS`, `REDIS_TIERED_TTL` | `10000`, `60s` | Entri store `tiered` per isolate dan umur terpanjangnya |
| `QUEUE_REDIS_ENGINE` | `list` | `stream` menyimpan job di stream dengan consumer group |
| `QUEUE_REDIS_NAMESPACE` | `daravel` | Ruang key untuk queue, terpisah dari `queues:` dari Laravel |

`/up/ready` mendapat pengecekan `redis` (`PING`). Password tidak pernah
muncul di log maupun error.

## Sentinel dan Cluster

```dotenv
# Master yang disebut Sentinel, ditemukan lagi setelah failover
REDIS_URL=redis+sentinel://:secret@10.0.0.21:26379,10.0.0.22:26379/mymaster/0

# Redis Cluster, dari node mana pun
REDIS_URL=redis+cluster://:secret@10.0.0.31:6379,10.0.0.32:6379
```

Dengan Sentinel, setiap koneksi menanyakan master ke para Sentinel lalu
mengecek `ROLE`-nya. Setelah failover, master lama memutus client-nya, yang
kemudian menyambung ke master baru; penulisan yang ditolak master yang
sudah diturunkan (`READONLY`) tidak sempat berjalan dan dikirim ulang ke
master baru. Penulisan yang diterima master lama sesaat sebelum Sentinel
menurunkannya bisa hilang: jendela itu berasal dari replikasi asinkron
Redis.

Di cluster, setiap perintah dikirim ke master hash slot key-nya, berdasarkan
slot map yang dibaca dengan `CLUSTER SLOTS` dan dikoreksi oleh `MOVED` dan
`ASK` saat slot berpindah. `MGET`, `DEL`, `UNLINK`, `EXISTS`, dan `TOUCH`
atas key dari beberapa slot dipecah per slot; `SCAN` (dan dengan demikian
`cache:clear`) mendatangi setiap master. Semua yang dijalankan Daravel
sebagai satu skrip berbagi hash tag (`{default}` untuk sebuah queue),
sehingga tetap di satu slot; skrip Anda sendiri atas beberapa key juga
membutuhkannya (`{user:7}:a`, `{user:7}:b`), atau server menjawab
`CROSSSLOT`. Cluster hanya punya database 0, jadi `REDIS_CACHE_DB` tidak
berlaku di sana.

## Cache di setiap isolate

`CACHE_STORE=tiered` menyimpan apa yang dibaca setiap isolate di memorinya
sendiri (L1) di depan Redis (L2), dan Redis memberi tahu setiap server saat
salah satu key itu ditulis (`CLIENT TRACKING` dalam mode broadcast, RESP3).
Pembacaan dari L1 tidak pernah lebih lama dari penulisan terakhir yang
diberitahukan ke server itu; yang memisahkannya hanyalah perjalanan singkat
pemberitahuan tersebut.

```dart
final user = await Cache.store('tiered').remember('user:7', null, loadUser);
```

Nilainya disimpan di bawah prefix tersendiri (`tiered:`), sehingga hanya
nilai-nilai itu yang di-broadcast; lock dan rate limit tetap ke store
`redis` seperti biasa. Selama tracking belum berjalan, dan di server yang
tidak mendukungnya, setiap pembacaan langsung ke Redis. Sebuah entri hidup
paling lama `REDIS_TIERED_TTL` dan mengikuti time to live key-nya sendiri;
paling banyak `REDIS_TIERED_MAX_KEYS` yang disimpan, dan yang paling lama
tidak dibaca keluar lebih dulu.

## Engine queue

`QUEUE_REDIS_ENGINE=list` (default) menyimpan job di list dan sorted set.
`stream` menyimpannya di Redis stream yang dibaca oleh consumer group:
server sendiri yang mencatat job yang sedang berjalan (`XPENDING`), dan job
yang worker-nya mati diambil worker lain setelah `QUEUE_RETRY_AFTER`
(`XAUTOCLAIM`, menurut jam server). Keduanya membangunkan worker yang
menganggur dengan cara yang sama, dan payload-nya tetap persis seperti yang
di-push. Ganti engine saat queue kosong: masing-masing menyimpan job di
key-nya sendiri.

## Algoritma rate limit

Fixed window dari Laravel bisa meloloskan sampai dua kali batas di sekitar
reset. Dengan `CACHE_LIMITER=redis`, dua algoritma lain masing-masing cukup
satu skrip, memakai jam server Redis:

```dart
limiter.define('login', (request) => Limit.perMinute(5).by(request.ip).gcra());
limiter.define('search', (request) => Limit.perMinute(60).slidingWindow());
```

| Algoritma | Yang dihitung |
| :-- | :-- |
| `fixedWindow` (default) | Cara Laravel: hit sejak hit pertama di jendela itu |
| `slidingWindow()` | Jendela saat ini ditambah jendela sebelumnya, ditimbang menurut seberapa banyak bagiannya masih dalam decay |
| `gcra()` | Satu percobaan setiap decay / batas, seluruh batas sebagai burst setelah periode sepi |

`Retry-After` menyebutkan kapan percobaan berikutnya akan lolos di
masing-masing algoritma.

## Facade `Redis`

```dart
await Redis.set('greeting', 'halo', ttl: const Duration(minutes: 5));
final greeting = await Redis.get('greeting');
await Redis.command(['HSET', 'user:7', 'name', 'Ana']);
final [name, ttl] = await Redis.connection().pipeline([
  ['HGET', 'user:7', 'name'],
  ['TTL', 'user:7'],
]);

final script = RedisScript("return redis.call('INCRBY', KEYS[1], ARGV[1])");
await Redis.eval(script, keys: ['visits'], args: [1]);

await Redis.publish('orders', '{"id":7}');
Redis.subscribe(['orders']).messages.listen((message) { /* ... */ });
```

Setiap isolate memegang satu koneksi per server, dan perintah yang dikirim
tanpa saling menunggu berbagi round trip-nya (pipelining). Perintah
blocking dan subscription mendapat koneksi sendiri; subscription akan
subscribe ulang setelah koneksinya terputus.

## Perintah

```dart
// bootstrap/commands.dart
import 'package:daravel_redis/commands.dart';

final List<CommandFactory> commands = [...redisCommands];
```

Perintah-perintah ini berasal dari library tersendiri, sehingga server
tidak ikut mengompilasi CLI.

| Perintah | Kegunaan |
| :-- | :-- |
| `redis:ping [--connection]` | Server, versinya, mode, dan round trip |
| `redis:stats [--connection]` | `INFO` setiap master (memori, client, hit) dan apa yang dikerjakan client (koneksi, redirect, failover) |
| `redis:keys-audit [--connection] [--match] [--limit]` | Key per tipe di bawah `REDIS_PREFIX`, dan key cache yang tidak pernah kedaluwarsa |
| `redis:cli [--connection] [--write] [command ...]` | Satu perintah, atau prompt; tanpa `--write` hanya perintah baca yang dijalankan (`KEYS` juga tidak: pakai `SCAN`) |

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
| Lock | Dibagi bila keduanya memakai `REDIS_PREFIX` dan `CACHE_PREFIX` yang sama: key yang sama di koneksi yang sama, `SET NX PX`, dan skrip pelepasan yang sama. `dartisan adopt` memberi Daravel prefix cache sendiri, jadi samakan `CACHE_PREFIX` dengan prefix dari Laravel untuk berbagi lock |
| Angka di cache | Dibagi: disimpan sebagai digit biasa |
| Nilai cache lainnya | Dibagi dengan `REDIS_SERIALIZER=php`: Daravel menulis `serialize()` dari PHP untuk string, boolean, list, dan map, serta membaca nilai dari Laravel, dengan object menjadi map berisi property-nya. Dengan `json`, Laravel tidak bisa membaca nilai dari Daravel |
| Queue | Dipisah (namespace `daravel:`): worker Laravel tidak bisa menjalankan job Daravel, begitu pula sebaliknya |

`bench/interop/redis.sh` mengecek semua ini terhadap Laravel 12 dengan
predis: lock yang diambil salah satunya ditolak bagi yang lain dengan
pemilik yang sama, angka di cache bertambah dari kedua sisi, dan
masing-masing membaca array yang di-cache sisi lainnya.

## Belum tersedia

Cache tags, Pub/Sub ber-shard (`SSUBSCRIBE`), Server-Sent Events yang bisa
dilanjutkan dari stream, dan perintah `redis:install` sudah direncanakan.
