<!-- source: README.md sha256:efcf7c9c2202 -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_test

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_test/README.md) · Bahasa Indonesia

Toolkit testing untuk aplikasi [Daravel](https://pub.dev/packages/daravel),
mengikuti semangat helper testing Laravel.

```bash
dart pub add dev:daravel_test
```

```dart
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

void main() {
  final db = refreshDatabase(createApp); // setiap test di-rollback

  test('creates a post', () async {
    final client = TestClient(db.app).actingAs(await UserFactory().create());
    (await client.post('/api/posts', json: {'title': 'Hello'}))
        .assertCreated()
        .assertJsonPath('data.title', 'Hello');
    await assertDatabaseHas('posts', {'title': 'Hello'});
  });
}
```

- `TestClient` dengan `actingAs`, `withToken`, `withHeaders`,
  `withoutExceptionHandling`, dan assertion `TestResponse` yang fluent.
- `refreshDatabase`, `assertDatabaseHas` / `Missing` / `Count`.
- Time travel (`freezeTime`, `travel`, `travelTo`) di atas `Clock`
  Daravel.
- Pengecekan arsitektur (`expectRegistryComplete`) dan integrasi lint.
- `package:daravel_test/conformance.dart`: kontrak format wire Laravel 12
  (`isLaravelValidationError`, `isLaravelErrorBody`,
  `isLaravelLengthAwarePaginator`, format token Sanctum, ...) untuk
  membuktikan API Anda masih "berbicara" Laravel.

Lihat [`example/main.dart`](example/main.dart) dan
[panduan testing](https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/testing.md).

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC. Daravel adalah proyek independen, tidak berafiliasi
dengan maupun didukung oleh keduanya.
