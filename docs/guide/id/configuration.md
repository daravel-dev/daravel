<!-- source: configuration.md sha256:3b5c8b57e712 -->
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
| `APP_ISOLATES` | `1` | Worker isolate HTTP |
| `DB_CONNECTION`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` | `sqlite` | `sqlite`, `pgsql`, `mysql`, atau `mariadb` (path di `DB_HOST` berarti Unix socket PostgreSQL) |
| `DB_URL` | | Satu URL sebagai pengganti key di atas, seperti di Laravel 12: `postgres://user:pass@host:5432/app?sslmode=require`. Bagian-bagiannya menggantikan nilai `DB_*` yang sesuai; yang tidak disebut tetap ([Database](database.md#url-database)) |
| `MAIL_MAILER` | `log` (`array` di test) | `smtp`, `log`, `array`, atau transport yang didaftarkan ([Mail](mail.md)) |
| `MAIL_SCHEME`, `MAIL_HOST`, `MAIL_PORT`, `MAIL_USERNAME`, `MAIL_PASSWORD` | `smtp`, `127.0.0.1`, `2525` | Server SMTP; `smtps` (atau port 465) untuk TLS sejak awal |
| `MAIL_FROM_ADDRESS`, `MAIL_FROM_NAME` | `hello@example.com`, `APP_NAME` | Pengirim default |
| `BROADCAST_CONNECTION` | `daravel` | Tujuan event broadcast: `daravel` (server ini), `reverb`, `pusher`, `log`, `null` ([Broadcasting](broadcasting.md)) |
| `REVERB_APP_ID`, `REVERB_APP_KEY`, `REVERB_APP_SECRET` | tidak ada | Aplikasi Pusher yang dipakai server ini untuk melayani Echo (atau Reverb tujuan pengiriman) |
| `REVERB_HOST`, `REVERB_PORT`, `REVERB_SCHEME` | tidak ada, 443, `https` | Reverb tujuan `BROADCAST_CONNECTION=reverb` |
| `DB_CHARSET`, `DB_COLLATION`, `DB_TIMEZONE` | `utf8mb4`, `utf8mb4_unicode_ci`, server | MySQL dan MariaDB, sebagaimana dibaca Laravel |
| `DB_POOL_SIZE`, `DB_SSLMODE` | `10`, `disable` | Pool koneksi per isolate, TLS (`require`, `verify-full`) |
| `CACHE_STORE`, `CACHE_PREFIX` | `memory` | Penyimpanan cache dan prefix key |
| `CACHE_PROCESS_L1_TTL` | `0` (mati) | Dengan store `process`, berapa lama setiap worker isolate memakai ulang nilai yang dibacanya (`250ms`) sebelum bertanya lagi ke coordinator |
| `CACHE_LIMITER` | coordinator | Penyimpanan cache untuk rate limit (`cache.limiter` dari Laravel); `database` membaginya antarmesin |
| `QUEUE_CONNECTION` | `sync` | `sync`, `memory`, atau `database` |
| `HASH_DRIVER`, `BCRYPT_ROUNDS` | `bcrypt`, `12` | Hashing password (seperti Laravel) |
| `LOG_LEVEL`, `LOG_STACK` | `debug` | Level log dan channel (`json` untuk produksi) |
| `SHUTDOWN_TIMEOUT`, `HTTP_REQUEST_TIMEOUT` | `30s`, `30s` | Graceful shutdown dan timeout handler |
| `SERVER_EMBED_QUEUE`, `SERVER_EMBED_SCHEDULER` | `false` | Queue worker dan scheduler di dalam proses server |

`dartisan doctor` mengecek konfigurasi dan koneksi database;
`doctor --production` memperlakukan peringatan sebagai kegagalan.
