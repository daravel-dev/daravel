# Dokumentasi Daravel

Daravel adalah framework backend Dart yang mengikuti filosofi Laravel 11/12
dan dikompilasi menjadi executable native (AOT). Jika Anda mengenal Laravel,
Anda sudah tahu letak semuanya: route, controller, form request, model gaya
Eloquent, migrasi, queue, scheduler, dan `artisan` (di sini `dartisan`).

Laravel dan Daravel dirancang untuk **berjalan berdampingan di database yang
sama**. JSON error dan paginasi, token Sanctum, hash bcrypt, payload `Crypt`,
dan tabel framework memakai format Laravel, dan suite konformansi menjaganya
tetap begitu. Lihat [Koeksistensi dengan Laravel](laravel-coexistence.md).

## Mengapa Daravel?

1. **Satu bundle native**: kode mesin AOT dengan SQLite terbawa; server tidak
   butuh runtime maupun source code ([Deployment](../deployment.md)).
2. **Tanpa reflection, tanpa `build_runner`**: generator menulis Dart biasa
   ke registry yang eksplisit.
3. **Semua core di satu port**: supervisor dengan worker isolate dan
   coordinator untuk lock, cache, dan rate limit, tanpa Redis.
4. **State request tetap di request-nya**: scope `Zone` untuk request, job,
   dan command; transaksi yang sadar zone.
5. **Berjalan berdampingan dengan Laravel** di database yang sama
   ([koeksistensi](laravel-coexistence.md),
   [migrasi bertahap](../migrating-from-laravel.md)).
6. **Route yang mendokumentasikan dirinya**: `.validates()` dan `.returns()`
   menjalankan 403/422 dan menghasilkan OpenAPI 3.1 ([Routing](../routing.md)).
7. **Pengaman bawaan**: hashing di compute isolate, lint AST, serta suite
   [keamanan](../security.md) dan konformansi.

Angka performa berasal dari harness yang bisa direproduksi, bukan klaim
([Performa](../performance.md)).

## Panduan

- [Memulai](getting-started.md)
- [Koeksistensi dengan Laravel](laravel-coexistence.md)
- [Keamanan & Hardening Sistem](security.md)
- [Panduan Deployment (Cloud Run & Native Bundle)](deployment.md)
- Panduan lain dalam bahasa Inggris: [Routing](../routing.md),
  [Validasi](../validation.md), [Database](../database.md),
  [Respons dan resource](../responses.md), [Autentikasi](../auth.md),
  [Cache, event, queue](../background.md), [Testing](../testing.md),
  [Migrasi bertahap dari Laravel](../migrating-from-laravel.md),
  [Performa](../performance.md), [Tabel paritas](../parity.md).

English: [Daravel documentation](../index.md).
