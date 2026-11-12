<!-- source: testing.md sha256:2403fb92a6d6 -->
# Testing

`package:daravel_test` menjalankan aplikasi Anda tanpa membuka socket:

<!-- include: packages/daravel/test/docs/guide_examples_test.dart#testing -->
```dart
(await client.get('/api/posts'))
    .assertOk()
    .assertJsonPath('data.0.title', 'Hello')
    .assertJsonPath('meta.total', 1);

(await client.post(
  '/api/posts',
  json: {'title': 'x'},
)).assertUnauthorized().assertJsonPath('message', 'Unauthenticated.');

(await client.get('/api/posts/99')).assertNotFound();
```
<!-- /include -->

- `TestClient(app)` dengan `actingAs(user)`, `withToken(token)`, `browser()`,
  `withSession`, `withCookie`, `followingRedirects()`,
  `withHeaders`, `withoutExceptionHandling()`.
- Assertion `TestResponse`: helper status, `assertJson`,
  `assertExactJson`, `assertJsonPath`, `assertJsonStructure`,
  `assertJsonValidationErrors`, header, cookie, `assertRedirect`, session
  (`assertSessionHas`, `assertSessionHasErrors`), dan guard
  (`assertAuthenticated`, `assertGuest`).
- `refreshDatabase(() => createApp(...))` menjalankan setiap test di dalam
  transaksi yang di-rollback (`RefreshDatabase` dari Laravel); `assertDatabaseHas` /
  `assertDatabaseMissing` / `assertDatabaseCount`.
- Fake: `Event.fake()`, `Queue.fake()`, `Storage.fake()`, dengan
  `assertDispatched`, `assertPushed`, ...
- Waktu: `freezeTime()`, `travel(duration)`, `travelTo(time)`; waktu domain
  membaca `Clock.now()`.
- Arsitektur: `expectRegistryComplete()` dan lint lewat `dartisan lint`.
- Form request: `expectFormRequestTyped(form, sampleInput, read: (input)
  => input.typed)` memvalidasi sebuah contoh input lalu membaca setiap
  field sebagai tipe yang dideklarasikan, sehingga `Field<int>` yang
  rule-nya meloloskan string gagal di sini, bukan sebagai 500 di produksi
  ([Validasi](validation.md#input-bertipe)). `make:request` menulis satu
  test seperti itu.

Jalankan suite-nya dengan `dartisan test` (`--coverage` menulis
`coverage/`).

### Aplikasi untuk test

`bootTestApp(createApp)` membuat aplikasi dengan environment test lalu
mem-boot-nya. `createApp` adalah fungsi di `bootstrap/app.dart`, bertipe
`TestAppFactory`. Environment-nya `testEnv()`:

- `APP_ENV=testing`
- `DB_CONNECTION=sqlite`
- `DB_URL=sqlite::memory:`, database baru untuk setiap aplikasi

Base path-nya direktori saat ini, yang oleh `dart test` diatur ke root
package. Sebelum:

```dart
setUp(() async {
  app = createApp(
    basePath: Directory.current.path,
    env: <String, String>{
      'APP_ENV': 'testing',
      'APP_NAME': 'Starter',
      'DB_CONNECTION': 'sqlite',
      'DB_URL': 'sqlite::memory:',
    },
  );
  await app.boot();
  client = TestClient(app);
});
tearDown(() => app.shutdown());
```

Sesudah:

```dart
setUp(() async {
  app = await bootTestApp(createApp, env: {'APP_NAME': 'Starter'});
  client = TestClient(app);
});
tearDown(() => app.shutdown());
```

Nilai `env` diterapkan sesudah environment test, sehingga bisa
menggantinya. Mematikan aplikasi tetap menjadi langkah test, di dekat
tempat ia dijalankan. Dengan `refreshDatabase`, berikan `testEnv()`
sendiri: `refreshDatabase(() => createApp(basePath: Directory.current.path,
env: testEnv()))`.

## Route web: cookie, session, dan CSRF

Test di Laravel menyimpan session di memori antar-request dan melewati
CSRF. Daravel membaca session dari cookie-nya di setiap request dan tetap
memeriksa CSRF di dalam test, jadi test untuk route `web` berperilaku seperti
browser: `client.browser()` menyimpan cookie yang di-set aplikasi di sebuah
`CookieJar` dan mengirimkannya kembali, meminta HTML, dan mengirim cookie
`XSRF-TOKEN` kembali sebagai header `X-XSRF-TOKEN` pada `POST`, `PUT`,
`PATCH`, dan `DELETE`, seperti yang dilakukan Axios, sehingga
`VerifyCsrfToken` menerima request tersebut:

```dart
final browser = TestClient(app).browser();

(await browser.get('/login')).assertOk().assertCookie('XSRF-TOKEN');

(await browser.post('/login', form: {'email': 'ana@x.io', 'password': 'wrong'}))
    .assertRedirect('/login')
    .assertSessionHasErrors(['email'])
    .assertSessionHasInput('email', 'ana@x.io')
    .assertGuest(guard: 'web');

(await browser.post('/login', form: {'email': 'ana@x.io', 'password': 'secret'}))
    .assertRedirect('/dashboard')
    .assertAuthenticatedAs(ana, guard: 'web');

(await browser.followingRedirects().post('/logout')).assertOk().assertGuest();
```

- `browser(xsrf: false)` tidak menambahkan header, untuk menguji `419`
  karena token tidak ada; form yang mengirim field `_token` tetap lolos.
- `followingRedirects()` mengikuti redirect dengan `GET` dan mengembalikan
  respons terakhir, dengan cookie dari setiap langkah tetap disimpan.
- `withSession({'cart': [...]})` memasukkan data ke session yang dimulai
  group `web`. Client browser mengisinya hanya pada request berikutnya, lalu
  session tersebut bertahan lewat cookie; client lain mengisinya di setiap
  request.
- `withCookie(name, value)` / `withCookies` mengirim cookie yang dienkripsi
  seperti yang diharapkan `EncryptCookies` (`CookieValuePrefix` dari Laravel
  dengan key aplikasi); `withUnencryptedCookie` / `withUnencryptedCookies`
  mengirimnya apa adanya.
- Pada respons: `assertSessionHas(key, [value])` (sebuah nilai, `Matcher`,
  atau `bool Function(Object?)`), `assertSessionHasAll`,
  `assertSessionMissing`, `assertSessionHasInput`, `assertSessionHasErrors`
  (satu field, list, atau map dari field ke pesan),
  `assertSessionDoesntHaveErrors`, `assertSessionHasNoErrors`;
  `assertCookie`, `assertPlainCookie`, `assertCookieExpired`,
  `assertCookieNotExpired`, `assertCookieMissing`; `assertRedirect('/path')`
  (path dan URL absolut dari halaman yang sama dianggap cocok) dan
  `assertRedirectContains`.
- `assertAuthenticated(guard:)`, `assertGuest(guard:)`, dan
  `assertAuthenticatedAs(user, guard:)` membaca user yang dimiliki setiap
  guard saat request selesai. Guard di Laravel bertahan melewati request;
  di sini guard yang tidak ditanya selama request (tanpa middleware `auth`,
  tanpa `Auth.user()`, tanpa login) dihitung sebagai guest, dan
  `assertAuthenticated` menyebutkannya: lakukan assertion pada respons
  login atau pada halaman di balik `auth`.

Assertion session membutuhkan group `web` dari `daravel_session` pada
route tersebut; `daravel_test` membaca session lewat interface core
`SessionStore` dan tidak bergantung pada package itu. Semua ini juga
bekerja lewat transport socket.

## Di dalam proses atau lewat socket

`TestClient` memanggil `Application.handle` secara langsung: cepat, dan
cukup untuk sebagian besar test. Apa yang dilakukan `dart:io` sendiri
terhadap respons (header default, `HEAD`, `Content-Length`, kompresi) hanya
terlihat di socket sungguhan, jadi test yang sama bisa dijalankan melalui
`ServerEngine` sungguhan di port loopback:

```bash
DARAVEL_TEST_TRANSPORT=socket dart test      # setiap TestClient di suite
```

```dart
final client = TestClient(app, transport: TestTransport.socket);  // satu client
```

Aplikasi melihat request yang sama dengan cara mana pun (host `localhost`,
byte JSON, form, dan multipart yang sama), `actingAs`, `withSession`, serta
assertion session dan guard tetap bekerja, redirect hanya diikuti dengan
`followingRedirects()`, dan body gzip tidak dibuka. Dua hal tetap di dalam proses:
`withoutExceptionHandling()` (exception tidak bisa menyeberangi socket) dan
header yang tidak bisa dikirim `HttpClient` (nilai non-ASCII, seperti pada
fuzzing). Di bawah `refreshDatabase`, server berjalan di dalam transaksi
milik test. Menjalankan suite dengan kedua cara di CI menangkap apa yang
tidak terlihat oleh test di dalam proses.

## Di browser (Playwright)

`TestClient` menguji aplikasi dari dalam. Suite end-to-end mengujinya dari
luar, seperti yang dilihat browser dan HTTP client: halaman tampil tanpa
error di console, header terkirim, token dari login membuka
`/api/auth/me` sampai logout, dan login keenam dalam satu menit dijawab
429. Daravel memakai [Playwright](https://playwright.dev) (Laravel memakai
Dusk), yang membutuhkan Node.js 20+:

```bash
dartisan e2e:install            # tests/e2e: konfigurasi dan spec
cd tests/e2e && npm install && npx playwright install chromium
dartisan test:e2e --serve       # menyalakan aplikasi dengan database baru, lalu menjalankan suite
```

`--serve` menjalankan `migrate:fresh --seed` pada `database/e2e.sqlite` dan
`serve` di port 8000 (`--port`), dan memakai ulang server yang sudah
berjalan di sana. `--serve` selalu memakai file SQLite tersebut
(`E2E_DATABASE` menunjuk file lain), bukan database di `.env`, sehingga tidak
bisa menghapus tabel yang dipakai bersama Laravel; proyek yang migrasinya
membutuhkan PostgreSQL atau MySQL menguji server yang sudah berjalan dengan
`--url`. Untuk server lain, situs DDEV atau staging: `dartisan
test:e2e --url=https://shop.ddev.site` (sertifikat TLS lokal diterima).
`--api` hanya menjalankan spec `*.api.spec.ts`, lewat HTTP tanpa browser;
`--ui` membuka UI mode Playwright; argumen setelah `--` diteruskan ke
Playwright (`dartisan test:e2e -- -g login`). `dartisan make:e2e Checkout`
menambahkan `specs/web/checkout.spec.ts`, dan `--api` membuat spec API.

Spec-spec ini memakai satu server bersama, jadi berjalan di satu worker:
database dan rate limit-nya adalah yang sebenarnya (lima registrasi per
menit per IP di project baru). Suite di starter berjalan di CI pada
setiap commit.

## Test konformansi

`package:daravel_test/conformance.dart` menyediakan kontrak wire Laravel 12
sebagai matcher, sehingga aplikasi bisa membuktikan bahwa aplikasinya masih
"berbicara" Laravel:

```dart
import 'package:daravel_test/conformance.dart';

expect(response.json, isLaravelValidationError({'email': ['The email field is required.']}));
expect(response.json, isLaravelErrorBody(LaravelContract.unauthenticated));
expect(token, matches(LaravelContract.sanctumPlainTextToken));
expect(body, isLaravelLengthAwarePaginator());
```

Proyek baru menyertakan `test/conformance/` dan `dart_test.yaml`; jalankan
dengan `dartisan test --conformance`.

## Padanan Laravel

Bagian lain dari Laravel yang ikut didukung, beserta API yang bisa dicari di pub.dev.

| Laravel | Daravel | API | Catatan |
| :-- | :-- | :-- | :-- |
| `$this->actingAs($user)` | `client.actingAs(user)` | `TestClient.actingAs` |  |
| `->assertOk() / assertCreated() / assertUnprocessable()` | `.assertOk() / .assertCreated() / .assertUnprocessable()` | `TestResponse.assertUnprocessable` |  |
