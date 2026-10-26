<!-- source: laravel-coexistence.md sha256:8d771f596c20 -->
# Koeksistensi dengan Laravel

Tujuan produk Daravel adalah aplikasi Laravel dan aplikasi Daravel bisa
berjalan berdampingan di database yang sama, dan sebuah codebase bisa
berpindah ke arah mana pun. Itu bisa terjadi karena format yang dibaca dan
ditulis kedua sisi adalah format Laravel, dan **suite konformansi**
menguncinya:

- `packages/daravel/test/conformance/` menjalankan setiap kontrak di bawah ini
  terhadap framework (`dart test --tags conformance`);
- fixture-nya mengutip sumber Laravel 12 / Sanctum 4 asalnya
  (`packages/daravel_test/lib/src/conformance/`), dan pesan validasi
  dibangkitkan dari `lang/en/validation.php` dari Laravel
  (`dart run tool/conformance/sync_laravel_messages.dart`);
- aplikasi mendapat matcher yang sama dari
  `package:daravel_test/conformance.dart`.

## Pengaturan untuk database bersama

```dotenv
APP_KEY=base64:...        # kunci yang sama dengan aplikasi Laravel
```

Hanya itu: default Daravel sama dengan Laravel (ADR-024), yaitu
`APP_CIPHER=AES-256-CBC` dan `HASH_DRIVER=bcrypt`. Jika aplikasi Laravel
mengubahnya, samakan nilainya.

## Apa yang dibagi, dan bagaimana

| Area | Kontrak |
| :-- | :-- |
| Tabel `migrations` | `id`, `migration`, `batch`; migrasi framework memakai nama dari Laravel (`0001_01_01_000001_create_cache_table`, ...) |
| `users` | kolom skeleton Laravel 12 |
| `cache`, `cache_locks` | skema Laravel 12, termasuk index `expiration` |
| `jobs`, `job_batches`, `failed_jobs` | skema Laravel 12 |
| `personal_access_tokens` | skema Sanctum 4; token `{id}\|{40 karakter}{crc32b}`, yang disimpan SHA-256-nya; `tokenable_type` = `App\Models\User` |
| `notifications` | skema Laravel 12; `type` `App\Notifications\...`, `notifiable_type` adalah `morphClass` model, `data` JSON ([Mail](mail.md)) |
| `features` | skema dan serialisasi scope Pennant ([Feature flag](feature-flags.md)) |
| Password | bcrypt `$2y$` dua arah (hash argon2id butuh dukungan argon2 di PHP) |
| String `Crypt` | `base64(json{iv, value, mac, tag})`, AES-256-CBC + HMAC atau AES-256-GCM |
| Error JSON | body dan pesan 401/403/404/405/413/422/429/500, lihat [Respons](responses.md) |
| Paginasi | body `paginate`, `simplePaginate`, `cursorPaginate`, jendela link, encoding cursor |
| Resource | `{data}`, `{data, links, meta}` |
| Tanggal | `2026-01-02T03:04:05.000000Z` |
| Route | nama, URI, dan parameter `apiResource` |

## Perbedaan yang disengaja

| Laravel | Daravel | Alasannya |
| :-- | :-- | :-- |
| `Crypt::encrypt()` memakai PHP `serialize()` | JSON | Belum ada serializer PHP (Tier 2); pakai varian `*String` lintas runtime |
| `HASH_VERIFY` menolak driver lain | menerima bcrypt dan argon2id saat driver diganti | Agar `rehashPasswordIfRequired` bisa meng-upgrade hash lama (ADR-024) |
| JSON meng-escape `/` dan non-ASCII (`\/`, `é`) | UTF-8 apa adanya | Setara setelah di-decode; cursor memakai escaping PHP |
| `$model->with(...)` | `with_(...)` | `with` adalah kata kunci Dart |
| Rule URL menerima panjang berapa pun | menolak > 8 192 karakter | Waktu validasi yang terbatas (suite keamanan) |

## Di mana Dart sengaja berbeda dari PHP

Beberapa idiom Laravel tidak mungkin ada di bahasa yang dikompilasi AOT dan
bertipe statis. Daravel mempertahankan tujuannya dan mengubah mekanismenya:

| Laravel (PHP) | Mengapa tidak bisa dibawa | Daravel |
| :-- | :-- | :-- |
| I/O sinkron: `User::find(1)` | Dart menjalankan I/O di event loop | `await User.query().find(1)` |
| Property dan method ajaib (`__get`, `__call`) | Tidak ada reflection di biner AOT (`dart:mirrors` tidak tersedia) | Accessor bertipe yang ditulis `dartisan make:model` / `model:sync` |
| Autoloading dan pemindaian folder | Compiler AOT membuang kode yang tidak pernah di-import `main()` | Registry eksplisit di `bootstrap/`, dirawat oleh `make:*` dan dicek `dartisan lint` |
| Parameter controller yang diinjeksi (`store(StoreRequest $r, User $u)`) | Signature tidak bisa diintrospeksi saat runtime | Handler menerima `Request`; `FormRequest.run`, `request.param<T>()`, dan route model binding |
| Satu tipe `array` dan perbandingan longgar | Sound null safety; `List` dan `Map` adalah tipe yang berbeda | `ValidatedData`, map, dan list yang bertipe |
| `eval` dan closure di queue | Tidak ada compiler di dalam biner; closure tidak bisa menyeberang proses | Job adalah kelas `Job` yang didaftarkan di `bootstrap/jobs.dart` |
| UI reflektif yang dikendalikan server (Livewire, Filament, Nova) | Bergantung pada hydration property secara reflektif | Flutter (web, mobile, desktop) atau SPA di atas API JSON |

## Yang belum dibagi

Session, CSRF, dan cookie (Tier 2).

**Queue.** Kedua framework bisa memakai satu tabel `jobs`, tetapi
masing-masing hanya menjalankan job miliknya sendiri: payload Laravel
membawa command yang di-serialize PHP, sedangkan payload Daravel membawa job
Dart yang terdaftar. Worker Daravel mengenali job Laravel dan melewatinya
tanpa menyentuhnya (tidak di-reserve, `attempts` tidak berubah, dicatat
sekali di log), sehingga worker Laravel tetap memprosesnya. Worker Laravel
tidak bisa melakukan hal yang sama untuk job Daravel, jadi beri Daravel nama
queue sendiri, misalnya `Queue.dispatch(job).onQueue('daravel')` dengan
`dartisan queue:work --queue=daravel`, dan biarkan `queue:work` Laravel di
queue miliknya.
[Tabel paritas](../parity.md) mencantumkan setiap API yang dipetakan dan apa
yang belum ada. Untuk memindahkan aplikasi endpoint demi endpoint, lihat
[Migrasi dari Laravel](migrating-from-laravel.md).
