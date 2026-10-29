<!-- source: laravel-coexistence.md sha256:faafbd025598 -->
# Koeksistensi dengan Laravel

Tujuan produk Daravel adalah aplikasi Laravel dan aplikasi Daravel bisa
berjalan berdampingan di database yang sama, dan sebuah codebase bisa
berpindah ke arah mana pun. Itu bisa terjadi karena format yang dibaca dan
ditulis kedua sisi adalah format Laravel, dan **suite konformansi**
menguncinya:

- `packages/daravel/test/conformance/` menjalankan setiap kontrak di bawah ini
  terhadap framework (`dart test --tags conformance`);
- fixture-nya mengutip sumber Laravel 13 / Sanctum 4 asalnya (Laravel 10
  sampai 12 menulis format yang sama, ADR-025)
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

### Versi Laravel yang lebih lama

Laravel 10, 11, 12 dan 13 mengirim pesan validasi, ringkasan 422, dan pesan
404/405 yang sama, sehingga tidak perlu pengaturan tambahan. Untuk aplikasi
di Laravel yang lebih lama, yang client-nya mungkin menampilkan atau
membandingkan string ini, set versi mayornya:

```dotenv
COMPAT_LARAVEL_VERSION=8
```

| `COMPAT_LARAVEL_VERSION` | Pesan validasi | `message` 422 | Route tidak dikenal (404) | Method salah (405) |
| :-- | :-- | :-- | :-- | :-- |
| `10` sampai `13` (default `12`) | `The email field must be a valid email address.` | error pertama + `(and N more errors)` | `The route api/x could not be found.` | `... not supported for route api/x. ...` |
| `9` | `The email must be a valid email address.` | sama dengan 10 | sama dengan 10 | sama dengan 10 |
| `8` | sama dengan 9 | `The given data was invalid.` | kosong | `... not supported for this route. ...` |

Pesan yang di-set aplikasi sendiri (`messages:` atau translation) dipakai
apa adanya. `Response.json(data, phpCompatible: true)` menulis byte yang
sama dengan `json_encode()` PHP (`\/`, escape `\u`, `[]` untuk map kosong),
untuk client yang membandingkan atau menandatangani body respons.

JSON model tidak memerlukan switch versi: Laravel 8 sampai 13 menyerialkan
model dengan cara yang sama, dan `Model.toJson` mengikutinya. Entri
`appends:` yang menamai atribut yang sudah ada menggantikannya di tempat
(posisi key sama), dan cast `datetime:FORMAT`, di Daravel
`Cast.dateTimeFormat('Y-m-d H:i:s')`, ditulis dalam format `date()` PHP
tersebut dalam UTC, seperti Laravel menulis `created_at` yang diformat
(timestamp diserialkan ke UTC sebelum diformat). Tanggal tanpa format tetap
ISO-8601 UTC (`Carbon::toJSON()`).

## Apa yang dibagi, dan bagaimana

| Area | Kontrak |
| :-- | :-- |
| Tabel `migrations` | `id`, `migration`, `batch`; migrasi framework memakai nama dari Laravel (`0001_01_01_000001_create_cache_table`, ...) |
| `users` | kolom skeleton Laravel 13 |
| `cache`, `cache_locks` | skema Laravel 13, termasuk index `expiration` |
| `jobs`, `job_batches`, `failed_jobs` | skema Laravel 13 |
| `personal_access_tokens` | skema Sanctum 4; token `{id}\|{40 karakter}{crc32b}`, yang disimpan SHA-256-nya; `tokenable_type` = `App\Models\User` |
| `notifications` | skema Laravel 13; `type` `App\Notifications\...`, `notifiable_type` adalah `morphClass` model, `data` JSON ([Mail](mail.md)) |
| `features` | skema dan serialisasi scope Pennant ([Feature flag](feature-flags.md)) |
| Broadcasting | protokol Pusher dari Laravel Reverb: Echo terhubung ke Daravel, `/broadcasting/auth` menandatangani seperti Laravel, Laravel mem-broadcast lewat Daravel dan Daravel lewat Reverb, notifikasi di `private-App.Models.User.{id}` ([Broadcasting](broadcasting.md)) |
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
| `QueryException` menulis binding ke pesannya | mempertahankan placeholder `?` | Nilai (hash password, email) tidak masuk log; nilainya ada di `bindings` |

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
