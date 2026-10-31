<!-- source: configuration.md sha256:e4b7ee963c39 -->
# Konfigurasi

## File environment

Konfigurasi berasal dari environment, dibaca dengan urutan ini (yang
belakangan menang):

1. `.env` di root proyek;
2. `.env.{APP_ENV}` (misalnya `.env.testing`), bila `APP_ENV` di-set;
3. environment proses;
4. override yang diberikan di kode (`withEnv({...})`, dipakai oleh test).

Sintaksnya sama dengan Laravel (phpdotenv 5): komentar, `export`, kutip
tunggal dan ganda, escape di dalam kutip ganda, nilai berkutip ganda yang
membentang beberapa baris, dan referensi `${NAME}`. `$NAME` tanpa kurung
kurawal tetap seperti yang ditulis, jadi password seperti `p$ss` terbaca
sama di Laravel dan Daravel.

`dartisan key:generate` menulis `APP_KEY` baru. Tanpa `.env`, `APP_ENV`
default-nya `production`.

## File environment terenkripsi

`dartisan env:encrypt` menulis `.env.encrypted` dalam format
`php artisan env:encrypt`; set `DARAVEL_ENV_ENCRYPTION_KEY` (atau
`LARAVEL_ENV_ENCRYPTION_KEY`) dan aplikasi mendekripsinya di memori saat
boot. Lihat [Deployment](deployment.md#secret-file-environment-terenkripsi).

## Konfigurasi bertipe

Setiap modul membaca variabelnya ke dalam section bertipe (`AppConfig`,
`DatabaseConfig`, `CacheConfig`, `QueueConfig`, ...), yang divalidasi saat
boot: mode debug di produksi, `APP_KEY` yang rusak, atau `DB_CONNECTION`
yang tidak dikenal menghentikan aplikasi dengan pesan yang jelas.

```dart
final app = Config.section<AppConfig>();      // bertipe
final name = Config.get<String>('app.name');  // notasi titik, seperti config()
```

Pengaturan Anda sendiri juga mendapat section:

```dart
final class BillingConfig implements ConfigSection {
  BillingConfig(this.currency, this.trialDays);

  factory BillingConfig.fromEnv(Env env) => BillingConfig(
    env.string('BILLING_CURRENCY', 'IDR'),
    env.integer('BILLING_TRIAL_DAYS', 14),
  );

  final String currency;
  final int trialDays;

  @override
  String get key => 'billing';

  @override
  Map<String, Object?> toMap() => {'currency': currency, 'trial_days': trialDays};
}

// bootstrap/app.dart
Application.configure(basePath: '.').withConfig(BillingConfig.fromEnv);
```

`Env` punya pembaca bertipe: `string`, `integer`, `boolean`, `duration`
(`30s`, `5m`, `500ms`), `list`, `url`, dan `enumValue`. Konfigurasi dibekukan
setelah boot.

## Variabel umum

| Variabel | Default | Kegunaan |
| :-- | :-- | :-- |
| `APP_ENV`, `APP_DEBUG` | `production`, `false` | Environment dan output debug |
| `APP_KEY`, `APP_PREVIOUS_KEYS` | tidak ada | Enkripsi, signed URL, token; rotasi kunci |
| `APP_CIPHER` | `AES-256-CBC` | Cipher `Crypt` (seperti Laravel) |
| `APP_HOST`, `APP_PORT`, `PORT` | `127.0.0.1`, `8000` | Alamat server; `PORT` untuk platform container |
| `APP_ISOLATES` | `1` | Worker isolate HTTP ([Operasional](operations.md#isolate)) |
| `APP_PROCESSES` | `1` | Proses server di port berurutan di belakang proxy ([Deployment](deployment.md#beberapa-proses)); butuh penyimpanan bersama atau `APP_PROCESSES_ALLOW_UNSHARED_STATE` |
| `SESSION_DRIVER`, `SESSION_LIFETIME`, `SESSION_COOKIE` | `file`, `120`, `<app>_session` | Session, cookie terenkripsi, dan CSRF, dengan `daravel_session` ([Session](sessions.md)) |
| `COMPAT_LARAVEL_VERSION` | `12` | Versi mayor Laravel (8 sampai 13) yang body error dan validasinya dipakai aplikasi ([Koeksistensi dengan Laravel](laravel-coexistence.md#versi-laravel-yang-lebih-lama)) |
| `DB_CONNECTION`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` | `sqlite` | `sqlite`, `pgsql`, `mysql`, atau `mariadb` (path di `DB_HOST` berarti Unix socket PostgreSQL) |
| `DB_URL` | | Satu URL sebagai pengganti key di atas, seperti di Laravel 12: `postgres://user:pass@host:5432/app?sslmode=require`. Bagian-bagiannya menggantikan nilai `DB_*` yang sesuai; yang tidak disebut tetap ([Database](database.md#url-database)) |
| `MAIL_MAILER` | `log` (`array` di test) | `smtp`, `log`, `array`, atau transport yang didaftarkan ([Mail](mail.md)) |
| `MAIL_SCHEME`, `MAIL_HOST`, `MAIL_PORT`, `MAIL_USERNAME`, `MAIL_PASSWORD` | `smtp`, `127.0.0.1`, `2525` | Server SMTP; `smtps` (atau port 465) untuk TLS sejak awal |
| `MAIL_FROM_ADDRESS`, `MAIL_FROM_NAME` | `hello@example.com`, `APP_NAME` | Pengirim default |
| `BROADCAST_CONNECTION` | `daravel` | Tujuan event broadcast: `daravel` (server ini), `reverb`, `pusher`, `log`, `null` ([Broadcasting](broadcasting.md)) |
| `REVERB_APP_ID`, `REVERB_APP_KEY`, `REVERB_APP_SECRET` | tidak ada | Aplikasi Pusher yang dipakai server ini untuk melayani Echo (atau Reverb tujuan pengiriman) |
| `REVERB_HOST`, `REVERB_PORT`, `REVERB_SCHEME` | tidak ada, 443, `https` | Reverb tujuan `BROADCAST_CONNECTION=reverb` |
| `REVERB_SCALING_ENABLED`, `REVERB_SCALING_CONNECTION` | `false`, koneksi default | Beberapa server berbagi broadcasting melalui database ([Broadcasting](broadcasting.md#beberapa-server)) |
| `REVERB_SCALING_DRIVER` | `database` | Sarana berbagi antarserver: `database`, atau `redis` dengan [daravel_redis](redis.md) |
| `REVERB_SCALING_POLL`, `REVERB_SERVER_ID` | `100ms`, nama host dan id proses | Seberapa sering server membaca event server lain tanpa `NOTIFY` (PostgreSQL memilikinya), dan nama server ini |
| `REVERB_ENCRYPTION_MASTER_KEY_BASE64` | tidak ada | 32 byte dalam base64 untuk mengenkripsi channel `private-encrypted-` (`PUSHER_ENCRYPTION_MASTER_KEY_BASE64` dengan `pusher`) |
| `DB_CHARSET`, `DB_COLLATION`, `DB_TIMEZONE` | `utf8mb4`, `utf8mb4_unicode_ci`, server | MySQL dan MariaDB, sebagaimana dibaca Laravel |
| `DB_STRICT`, `DB_SQL_MODES`, `DB_ISOLATION_LEVEL` | dari server | Pengaturan session MySQL dan MariaDB, seperti `'strict'`, `'modes'`, dan `'isolation_level'` di Laravel ([Database](database.md)) |
| `DB_POOL_SIZE`, `DB_SSLMODE` | `10`, `disable` | Pool koneksi per isolate, TLS (`require`, `verify-full`) |
| `DB_SEARCH_PATH` (atau `DB_SCHEMA`) | dari server | Schema PostgreSQL pada setiap koneksi (`billing, hr, public`), `'search_path'` dari Laravel |
| `DB_CONNECT_TIMEOUT`, `DB_QUERY_TIMEOUT` | `10`, `30` | Detik yang boleh dipakai koneksi PostgreSQL atau MySQL untuk terbuka, dan sebuah statement untuk berjalan (`0` untuk tanpa batas; statement yang macet akan menahan koneksi pool-nya selamanya) |
| `CACHE_STORE`, `CACHE_PREFIX` | `memory` | Penyimpanan cache dan prefix key |
| `CACHE_PROCESS_MAX_ENTRIES` | `10000` | Jumlah entri yang disimpan store `process` untuk seluruh server; yang paling lama tidak dipakai dibuang lebih dulu, jadi naikkan bila store ini menampung banyak key yang harus bertahan sampai kedaluwarsa (JWT yang dicabut, counter per client), atau simpan key itu di `database` atau Redis |
| `CACHE_PROCESS_L1_TTL` | `0` (mati) | Dengan store `process`, berapa lama setiap worker isolate memakai ulang nilai yang dibacanya (`250ms`) sebelum bertanya lagi ke coordinator |
| `CACHE_LIMITER` | coordinator | Penyimpanan cache untuk rate limit (`cache.limiter` dari Laravel); `database` membaginya antarmesin, dengan satu statement per percobaan |
| `QUEUE_CONNECTION` | `sync` | `sync`, `memory`, `database`, atau `redis` ([Redis](redis.md)) |
| `QUEUE_UNIQUE_LOCK_STORE` | `database` atau `redis` sesuai queue-nya, selain itu `process` | Cache store untuk lock unique job; proses `queue:work` harus bisa menjangkaunya |
| `QUEUE_SIGNAL_STORE` | `file` dengan queue database, selain itu lock store | Cache store untuk sinyal `queue:restart` dan `queue:pause`; `database` menjangkau worker di semua mesin |
| `HASH_DRIVER`, `BCRYPT_ROUNDS` | `bcrypt`, `12` | Hashing password (seperti Laravel) |
| `LOG_LEVEL`, `LOG_STACK` | `debug` | Level log dan channel (`json` untuk produksi) |
| `SHUTDOWN_TIMEOUT`, `HTTP_REQUEST_TIMEOUT` | `30s`, `30s` | Graceful shutdown dan timeout handler |
| `HTTP_IDLE_TIMEOUT` | `60s` | Koneksi keep-alive yang menganggur selama ini ditutup oleh server |
| `HTTP_MAX_BODY` | `52428800` (50 MiB) | Batas body yang dimiliki setiap request sejak awal (`413` di atasnya; `0` untuk tanpa batas); `BodyLimitsMiddleware` memperketatnya ke 1 MiB untuk JSON dan form |
| `HTTP_MAX_QUEUE_DELAY`, `HTTP_MAX_IN_FLIGHT` | mati (`200ms` di proyek baru), mati | [Load shedding](deployment.md#load-shedding): `503` selama event loop worker terlambat sebanyak ini, atau di atas sekian request sekaligus |
| `SERVER_EMBED_QUEUE`, `SERVER_EMBED_SCHEDULER` | `false` | Queue worker dan scheduler di dalam proses server |

`dartisan doctor` mengecek konfigurasi dan koneksi database;
`doctor --production` memperlakukan peringatan sebagai kegagalan dan
mewajibkan `APP_ENV=production`, karena pemeriksaan yang hanya berlaku di
sana akan terlewati tanpanya. Dengan `APP_ENV=production`, `APP_KEY` yang
kosong adalah error, `HASH_VERIFY=false`, `BCRYPT_ROUNDS` di bawah 10 dan `HTTP_MAX_BODY=0`
adalah peringatan, sedangkan `APP_URL` yang masih `http`,
`HASH_DRIVER=pbkdf2` dan rahasia di `.env` polos adalah catatan. Saran
tuning (satu isolate di mesin dengan core lebih banyak, `LOG_LEVEL` di bawah
`warning`, file SQLite yang dipakai bersama beberapa isolate, pool PostgreSQL
dibandingkan `max_connections`) dicetak sebagai `[note]` dan tidak pernah
menggagalkan; begitu pula `.env` yang tidak ada saat `APP_ENV` berasal dari
environment OS, seperti di container.
