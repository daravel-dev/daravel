<!-- source: testing.md sha256:bc1e48e0eb25 -->
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

- `TestClient(app)` dengan `actingAs(user)`, `withToken(token)`,
  `withHeaders`, `withoutExceptionHandling()`.
- Assertion `TestResponse`: helper status, `assertJson`,
  `assertExactJson`, `assertJsonPath`, `assertJsonStructure`,
  `assertJsonValidationErrors`, header.
- `refreshDatabase(createApp)` menjalankan setiap test di dalam transaksi
  yang di-rollback (`RefreshDatabase` dari Laravel); `assertDatabaseHas` /
  `assertDatabaseMissing` / `assertDatabaseCount`.
- Fake: `Event.fake()`, `Queue.fake()`, `Storage.fake()`, dengan
  `assertDispatched`, `assertPushed`, ...
- Waktu: `freezeTime()`, `travel(duration)`, `travelTo(time)`; waktu domain
  membaca `Clock.now()`.
- Arsitektur: `expectRegistryComplete()` dan lint lewat `dartisan lint`.

Jalankan suite-nya dengan `dartisan test` (`--coverage` menulis
`coverage/`).

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
byte JSON, form, dan multipart yang sama), `actingAs` tetap bekerja, redirect
tidak diikuti, dan body gzip tidak dibuka. Dua hal tetap di dalam proses:
`withoutExceptionHandling()` (exception tidak bisa menyeberangi socket) dan
header yang tidak bisa dikirim `HttpClient` (nilai non-ASCII, seperti pada
fuzzing). Di bawah `refreshDatabase`, server berjalan di dalam transaksi
milik test. Menjalankan suite dengan kedua cara di CI menangkap apa yang
tidak terlihat oleh test di dalam proses.

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
