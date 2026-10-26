<!-- source: index.md sha256:98c5a8ba104b -->
# Dokumentasi Daravel

Daravel adalah framework backend untuk Dart yang mengikuti filosofi Laravel
11/12 dan dikompilasi menjadi executable native AOT. Jika Anda mengenal
Laravel, Anda sudah tahu letak semuanya: route, controller, form request,
model ala Eloquent, migrasi, queue, scheduler, dan `artisan` (di sini
`dartisan`).

Laravel dan Daravel dirancang untuk **berjalan berdampingan di database yang
sama**. JSON error dan paginasi, token Sanctum, hash bcrypt, payload `Crypt`,
dan tabel-tabel framework memakai format Laravel, dan sebuah suite
konformansi menjaganya tetap begitu. Lihat [Koeksistensi dengan
Laravel](laravel-coexistence.md).

Paket resminya adalah `daravel`, `dartisan_cli`, `daravel_test`,
`daravel_lints`, `daravel_mysql`, `daravel_sqlite`, dan `daravel_postgres`,
dirilis bersama oleh publisher
terverifikasi [`daravel.teoprayoga.my.id`](https://pub.dev/publishers/daravel.teoprayoga.my.id)
di pub.dev; hanya paket dari publisher itu yang merupakan bagian dari
proyek ini. Daravel berjalan di server Linux, macOS, dan Windows (pub.dev
juga mencantumkan Flutter, karena paketnya Dart murni).

## Mengapa Daravel?

1. **Satu bundle native**: kode mesin AOT dengan SQLite terbawa; server tidak
   membutuhkan runtime maupun source code ([Deployment](deployment.md)).
2. **Tanpa reflection, tanpa `build_runner`**: generator menulis Dart biasa
   ke registry yang eksplisit.
3. **Semua core di satu port**: supervisor dengan worker isolate dan
   coordinator untuk lock, cache, dan rate limit, tanpa Redis.
4. **State request tetap di request-nya**: scope `Zone` untuk request, job,
   dan command; transaksi yang sadar zone.
5. **Berjalan berdampingan dengan Laravel** di database yang sama
   ([koeksistensi](laravel-coexistence.md),
   [migrasi](migrating-from-laravel.md)).
6. **Route yang mendokumentasikan dirinya sendiri**: `.validates()` dan
   `.returns()` menegakkan 403/422 dan menghasilkan OpenAPI 3.1
   ([Routing](routing.md)).
7. **Pengaman bawaan**: hashing di compute isolate, lint AST, serta suite
   [keamanan](security.md) dan konformansi.

Angka performa berasal dari harness yang bisa direproduksi, bukan dari klaim
([Performa](performance.md)).

## Panduan

1. [Memulai](getting-started.md): instalasi, membuat proyek, menjalankan, build.
2. [Routing](routing.md): route, grup, middleware, resource, rate limit.
3. [Validasi](validation.md): rule, form request, format 422.
4. [Database](database.md): migrasi, query builder, model, paginasi.
5. [Respons dan resource](responses.md): JSON, API resource, error.
6. [Autentikasi dan otorisasi](auth.md): token, JWT, hashing, Crypt, gate.
7. [Cache, event, queue, penjadwalan](background.md).
8. [Mail dan notifikasi](mail.md): SMTP, mailable, serta notifikasi mail dan database.
9. [Broadcasting](broadcasting.md): Laravel Echo, protokol Pusher seperti Reverb, channel private dan presence.
10. [String, helper, dan koleksi](helpers.md): `Str`, `retry`, `once`, `pluck`, ...
11. [HTTP client](http-client.md): request keluar dengan `Http`, retry, dan `Http.fake()`.
12. [Client Flutter](flutter-client.md): client bertipe yang dihasilkan dari route, dengan validasi di perangkat.
13. [Testing](testing.md): `TestClient`, helper database, fake, konformansi.
14. [Deployment](deployment.md): bundle native, Docker, Cloud Run, VPS (systemd + Caddy).
15. [Koeksistensi dengan Laravel](laravel-coexistence.md): kontrak kompatibilitas.
16. [Migrasi dari Laravel](migrating-from-laravel.md): pindahkan endpoint satu per satu di balik proxy.
17. [Keamanan](security.md): default yang aman dan suite keamanan.
18. [Performa](performance.md): harness benchmark.
19. [Tabel paritas Laravel ⇄ Daravel](../parity.md) (dihasilkan otomatis, dalam bahasa Inggris).

English: [Daravel documentation](../index.md).

Contoh kode di panduan ini disalin dari file yang dikompilasi dan diuji
(`packages/daravel/test/docs/guide_examples_test.dart`) oleh
`dart run tool/docs/generate.dart`, sehingga tidak bisa usang.
