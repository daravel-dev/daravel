<!-- source: releases.md sha256:812717ea3522 -->
# Rilis dan versioning

Daravel `1.x` adalah lini rilis stabil. Kesepuluh paket (`daravel`,
`dartisan_cli`, `daravel_test`, `daravel_lints`, `daravel_mysql`,
`daravel_sqlite`, `daravel_postgres`, dan sejak 1.12.0 `daravel_redis`,
`daravel_permission`, serta `daravel_teorion`) dirilis bersama dengan satu
versi,
dipublikasikan di [pub.dev](https://pub.dev/packages/daravel) oleh publisher
terverifikasi `framework.daravel.dev`.

| Versi | Sorotan |
| :-- | :-- |
| `1.12.0` | Redis dan Valkey (daravel_redis), role dan permission (daravel_permission), query filter (daravel_teorion), cache tags, eager loading kolom tertentu, exception unique violation bertipe, dan createOrFirst |
| `1.11.0` | Broadcasting lintas server (REVERB_SCALING_ENABLED), channel cache dan terenkripsi, 10k koneksi, rate limit satu statement, worker queue yang bisa dibangunkan |
| `1.10.1` | Perbaikan keamanan: pencabutan JWT di semua isolate, queue:restart dan queue:pause lintas proses, lock unique job |
| `1.10.0` | Broadcasting untuk Laravel Echo (protokol Pusher seperti Reverb; `ShouldBroadcast`, `BROADCAST_CONNECTION`), bcrypt C di Linux |
| `1.9.0` | Mail dan notifikasi (queue, tema markdown, channel broadcast), `Broadcast` lintas isolate, `DB_URL`, `dartisan upgrade`, panduan Bahasa Indonesia, benchmark dibanding Laravel |
| `1.8.1` | Perbaikan: adapter `client:flutter --state` tanpa paginator atau upload lolos `dart analyze --fatal-infos` |
| `1.8.0` | Paket driver, `db:install`, `db:transfer`, `withDatabaseConnection`; `client:flutter --state`/`--watch`; transaksi per koneksi |
| `1.7.0` | `dartisan client:flutter`: client Dart/Flutter bertipe dengan rule validasi server di perangkat |
| `1.6.0` | Server-sent events (`Response.sse`, frame `eventStream` Laravel) dan route WebSocket (`router.ws`) |
| `1.5.1` | Perbaikan: angka JSON di luar rentang double (`1e309`) menjadi 400, bukan 500 atau Infinity yang tersimpan |
| `1.5.0` | `daragic:export` (DAM), `TestTransport.socket`, `TouchableCacheStore.touch`; perbaikan rate limit bersama saat konkurensi |
| `1.4.1` | Perbaikan: header keamanan tidak lagi menumpuk antar-request di server yang berjalan |
| `1.4.0` | Referensi langsung `/docs/api`, lokalisasi (`trans`, `transChoice`, aturan plural 280 locale), `cache.headers` dan gzip, feature flag yang kompatibel dengan Pennant, `db:backup`; perbaikan respons `HEAD` |
| `1.3.0` | Registry model dan `model:show`, `mcp:serve` `models`/`db_query`/`read_logs`/`last_error`, `mcp:install`, `SCHEDULE_TIMEZONE`, lint `invalid_timezone`, image Docker tanpa SQLite; perbaikan `timezone('UTC')` |
| `1.2.0` | Binding DI dan `inject()`, helper string/tanggal/angka yang fluent, perhitungan kalender ala Carbon, shortcut query tanggal, `DB.whenQueryingForLongerThan`, `Context`, builder HTML bertipe, zona IANA di scheduler, `build --no-sqlite`, `mcp:serve` |
| `1.1.0` | Relasi polimorfik, `whereHas` bersarang, agregat relasi, input query sinkron, rule berantai, dua lint baru, near cache dan rate limit bersama; perbaikan transaksi konkuren, counter cache database, dan subquery PostgreSQL |
| `1.0.0` | Rilis stabil pertama: upload file, MySQL dan MariaDB (`daravel_mysql`), client `Http`, mode maintenance, `db:show`/`db:table`/`tinker` |
| `1.0.0-beta.3` | Metadata route (`.validates()`, `.returns()`) dan schema OpenAPI, input request bertipe, `.env.encrypted`, `dartisan adopt`, queue dan scheduler tertanam, jalur request yang lebih cepat |
| `1.0.0-beta.2` | Delegasi `dartisan`, halaman welcome, pengaman queue Laravel, fallback `PORT` |
| `1.0.0-beta.1` | Rilis publik pertama: framework Tier 1 lengkap |

Catatan lengkapnya ada di
[changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md)
dan di halaman [rilis GitHub](https://github.com/daravel-dev/daravel/releases).

## Versioning

- API Dart mengikuti SemVer: rilis `1.x` menambah fitur dan memperbaiki bug
  tanpa merusak kode yang ada; perubahan yang merusak menunggu `2.0`.
- Format yang berhadapan dengan Laravel (JSON error dan paginasi, token
  Sanctum, hash bcrypt, payload `Crypt`, tabel bersama) dikunci suite
  konformansi. Format itu hanya berubah agar lebih sesuai dengan Laravel, dan
  changelog menyebutkannya.
- Perbaikan keamanan dirilis untuk lini `1.x`; beta `1.0.0` tidak lagi
  didukung.

## Branch

Seperti Laravel, Daravel menyimpan satu branch per versi mayor. `main` adalah
tempat pengembangan; `1.x` mengikuti rilis `1.x` terbaru. Dokumentasi ini
tersedia untuk keduanya: `1.x` adalah default, `main` menjelaskan pekerjaan
yang belum dirilis.
