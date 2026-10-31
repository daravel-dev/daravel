<!-- source: sessions.md sha256:486f1fe9bcc5 -->
# Session, cookie, dan CSRF

`daravel_session` memberi route web sebuah session seperti di Laravel: id
session dibawa dalam cookie terenkripsi, atributnya disimpan di file atau di
tabel `sessions` Laravel sebagai teks PHP `serialize()` atau JSON, dan request
yang mengubah state harus membawa token CSRF. Aplikasi Laravel dan aplikasi
Daravel dengan `APP_KEY` dan penyimpanan yang sama berbagi session, cookie,
dan token seorang pengunjung.

```bash
dart pub add daravel_session
```

```dart
// bootstrap/app.dart
import 'package:daravel_session/daravel_session.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withSession()
    .withMigrations([...migrations, const CreateSessionsTable()])
    .withRouting(
      web: (Router router) => router.group((Router r) {
        r.get('/cart', (request) => request.session.get<List<Object?>>('cart'));
      }, middleware: const ['web']),
    )
    .create();
```

`withSession()` mendaftarkan tiga alias middleware dan grup `web` yang
menjalankannya dalam urutan Laravel:

| Alias | Middleware | Laravel |
| :-- | :-- | :-- |
| `encrypt_cookies` | `EncryptCookiesMiddleware` | `EncryptCookies` |
| `session` | `StartSessionMiddleware` | `StartSession` |
| `csrf` | `VerifyCsrfTokenMiddleware` | `VerifyCsrfToken` |

Pasang grup ini pada route yang membutuhkan session. Route API dengan bearer
token atau JWT tidak membutuhkannya, dan tidak menanggung biayanya.

## Pengaturan

| Variabel | Default | Fungsi |
| :-- | :-- | :-- |
| `SESSION_DRIVER` | `database` | `database` (tabel `sessions`, seperti laravel/laravel 11 sampai 13), `file` (`storage/framework/sessions`), atau `array` (test). Versi 1.18 memakai default `file`: set `SESSION_DRIVER=file` untuk mempertahankannya |
| `SESSION_LIFETIME` | `120` | Menit session boleh menganggur |
| `SESSION_EXPIRE_ON_CLOSE` | `false` | Cookie session tanpa masa berlaku |
| `SESSION_COOKIE` | `<nama app>_session` | Nama cookie, `Str::slug(APP_NAME, '_')` seperti Laravel menurunkannya (`my_app_session`) |
| `SESSION_TABLE`, `SESSION_CONNECTION` | `sessions`, default | Tabel dan koneksi driver `database` |
| `SESSION_PATH`, `SESSION_DOMAIN` | `/`, tidak ada | Cakupan cookie |
| `SESSION_SECURE_COOKIE`, `SESSION_HTTP_ONLY`, `SESSION_SAME_SITE` | `false`, `true`, `lax` | Flag cookie; `SESSION_SAME_SITE=none` butuh flag secure |
| `SESSION_ENCRYPT` | `false` | Simpan payload terenkripsi dengan `Crypt`, seperti `EncryptedStore` Laravel (`Crypt::encrypt(serialize($attributes))`) |
| `SESSION_PARTITIONED_COOKIE` | `false` | `Partitioned` (CHIPS) pada cookie session dan `XSRF-TOKEN`, untuk aplikasi yang disematkan di situs lain |
| `SESSION_SERIALIZATION` | `php`, `json` dengan `COMPAT_LARAVEL_VERSION=13` | Format session baru, `session.serialization` dari Laravel |

Kedua format selalu dibaca, dan session yang tersimpan ditulis kembali dalam
format aslinya, sehingga Daravel tidak pernah me-logout pengguna dari aplikasi
Laravel yang berbagi penyimpanan yang sama. `SESSION_SERIALIZATION` menentukan
format session yang dibuat Daravel, dan Laravel harus bisa membacanya: hanya
skeleton laravel/laravel 13 yang menetapkan `'serialization' => 'json'`,
sehingga aplikasi yang di-upgrade ke 13 bisa saja masih memakai `php`.
`dartisan adopt` membaca nilainya dari `config/session.php` proyek Laravel.

Dengan beberapa isolate atau server, pakai `database` (atau driver `file` di
satu mesin): driver `array` hanya memori satu isolate. `CreateSessionsTable`
membuat tabel Laravel dan tidak berbuat apa-apa bila tabelnya sudah ada.

## Session

```dart
final session = request.session;      // atau Session.current

session.put('cart.items', ['a']);     // key bertitik bersarang, seperti di Laravel
session.push('cart.items', 'b');
session.get<String>('name', 'guest');
session.pull<int>('hits');
session.increment('views');
session.forget('name');
session.flush();

session.flash('status', 'Saved.');    // hanya untuk request berikutnya
session.now('status', 'Saving...');   // hanya untuk request ini
session.reflash();
session.keep(['status']);

session.token;                        // token CSRF
await session.regenerate();           // id baru, token baru, data sama
await session.invalidate();           // flush + id baru (logout)
session.previousUrl;                  // halaman GET terakhir
```

Atribut ditulis kembali setelah respons sebagai teks `serialize()`, dengan
key Laravel untuk entri milik framework (`_token`, `_flash.old`,
`_flash.new`, `_previous.url`), sehingga aplikasi Laravel yang membaca file
atau baris yang sama melihat apa yang akan ditulisnya sendiri. Objek PHP
yang disimpan Laravel (misalnya `ViewErrorBag`) tiba sebagai `PhpObject`
dan ditulis kembali tanpa perubahan.

## Cookie

`EncryptCookiesMiddleware` mengenkripsi setiap cookie yang di-set respons
dan mendekripsi cookie yang dibawa request, dengan `Crypt` dan prefix nilai
Laravel (`hmac_sha1(name . 'v2', key) . '|'`), sehingga cookie tidak bisa
dipindahkan ke nama lain dan aplikasi Laravel membaca cookie yang sama.
Cookie yang gagal didekripsi dibuang dari request. Cookie yang harus tetap
terbaca oleh script atau sistem lain ditaruh di `withSession(cookiesExcept:
['theme'])`.

## CSRF

`VerifyCsrfTokenMiddleware` meloloskan `GET`, `HEAD`, dan `OPTIONS`, dan
mewajibkan token session pada method lainnya, dari input `_token`, header
`X-CSRF-TOKEN`, atau header `X-XSRF-TOKEN`. Setiap respons men-set cookie
`XSRF-TOKEN` (terenkripsi, terbaca oleh script), yang dikirim balik Axios
dan Angular sebagai `X-XSRF-TOKEN`. Token yang hilang atau salah dijawab
`419` dengan `{"message": "CSRF token mismatch."}`, seperti Laravel.
Webhook dan endpoint lain yang dipanggil tanpa session melewati pemeriksaan
lewat `withSession(csrfExcept: ['webhooks/*'])`.

```html
<form method="post" action="/profile">
  <input type="hidden" name="_token" value="{{ request.session.token }}">
</form>
```

## Login

`SessionGuard` adalah session guard Laravel. Guard ini menyimpan id user pada
key `login_web_<sha1>` yang sama, sehingga user yang login di salah satu
aplikasi juga login di aplikasi lainnya.

```dart
.withAuth((auth) => auth.session<User>('web', ModelUserProvider<User>(User.definition)))
```

```dart
final guard = App.make<AuthManager>().guard('web') as SessionGuard<User>;

await guard.attempt({'email': email, 'password': password}); // false bila tidak cocok
await guard.login(user);                                     // id session dan token baru
await guard.logout();
await request.session.invalidate();
```

`attempt(..., remember: true)` juga menulis cookie `remember_web_<sha1>` dari
Laravel. Cookie ini butuh kolom `remember_token` yang nullable, dan me-login-kan
user di kedua aplikasi setelah session habis; `logout` menghapusnya dan
mengganti token.
`guard.viaRemember` memberi tahu apakah user request ini berasal dari cookie itu.

Validasi yang gagal di grup `web` mengembalikan browser atau kunjungan Inertia
ke halaman sebelumnya, dengan status 303 setelah PUT, PATCH, atau DELETE dari
Inertia. `session.errors` dan `session.old('name')` tersedia di request
berikutnya, dan password tidak pernah di-flash. Client yang mengharapkan JSON
tetap menerima 422. Form menyebut verb-nya dengan `_method`, atau lewat header
`X-HTTP-Method-Override`; `middleware.methodOverride = false` mematikannya.

Pasang `auth:web` setelah grup `web` pada route yang dilindungi. Mulai
`COMPAT_LARAVEL_VERSION=12`, login juga menyimpan `password_hash_web` yang
dibandingkan oleh `AuthenticateSession` dari Laravel.

## Belum tercakup

Driver session `cookie`, `ViewErrorBag` (`back()->withErrors()`), dan session
blocking (`Route::block`). Tabel
`sessions` dan format cookie Laravel adalah kontraknya; selebihnya adalah
API Daravel sendiri.
