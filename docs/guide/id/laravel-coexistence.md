# Koeksistensi dengan Laravel

Tujuan produk Daravel adalah aplikasi Laravel dan Daravel bisa berjalan
berdampingan di database yang sama, dan kode bisa dipindahkan ke dua arah.
Ini mungkin karena format yang dibaca dan ditulis kedua sisi adalah format
Laravel, dan **suite konformansi** menguncinya:

- `packages/daravel/test/conformance/` menjalankan semua kontrak di bawah
  terhadap framework (`dart test --tags conformance`);
- fixture-nya mengutip sumber Laravel 12 / Sanctum 4 asalnya, dan pesan
  validasi dibangkitkan dari `lang/en/validation.php` milik Laravel
  (`dart run tool/conformance/sync_laravel_messages.dart`);
- aplikasi mendapat matcher yang sama dari
  `package:daravel_test/conformance.dart` (`dartisan test --conformance`).

## Pengaturan untuk database bersama

```dotenv
APP_KEY=base64:...        # kunci yang sama dengan aplikasi Laravel
```

Hanya itu: default Daravel sama dengan Laravel (ADR-024), yaitu
`APP_CIPHER=AES-256-CBC` dan `HASH_DRIVER=bcrypt`. Jika aplikasi Laravel
mengubahnya, samakan nilainya.

## Yang dibagi

- Tabel `migrations`, `users`, `cache`, `cache_locks`, `jobs`,
  `job_batches`, `failed_jobs`, `personal_access_tokens`: skema Laravel 12
  dan Sanctum 4, dengan nama migrasi yang sama.
- Token Sanctum `{id}|{40 karakter}{crc32b}`; tabel menyimpan SHA-256-nya;
  `tokenable_type` = `App\Models\User`.
- Password bcrypt `$2y$` dua arah.
- String `Crypt` (AES-256-CBC + HMAC atau AES-256-GCM).
- Body JSON error 401/403/404/405/413/422/429/500, paginasi (termasuk cursor),
  resource, dan format tanggal `2026-01-02T03:04:05.000000Z`.

## Perbedaan yang disengaja

- `Crypt::encrypt()` Laravel memakai PHP `serialize()`, Daravel memakai JSON:
  gunakan varian `*String` lintas runtime.
- `HASH_VERIFY` di Daravel tetap menerima hash bcrypt dan argon2id saat
  driver diganti, agar `rehashPasswordIfRequired` bisa meng-upgrade hash
  lama saat login (ADR-024).
- Eager loading `with(...)` menjadi `with_(...)` karena `with` adalah kata
  kunci Dart.

Detail lengkap: [Laravel coexistence](../laravel-coexistence.md) (Inggris).
