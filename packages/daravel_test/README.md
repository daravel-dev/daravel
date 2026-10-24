<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_test

Testing toolkit for [Daravel](https://pub.dev/packages/daravel)
applications, in the spirit of Laravel's testing helpers.

```bash
dart pub add dev:daravel_test
```

```dart
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

void main() {
  final db = refreshDatabase(createApp); // each test rolls back

  test('creates a post', () async {
    final client = TestClient(db.app).actingAs(await UserFactory().create());
    (await client.post('/api/posts', json: {'title': 'Hello'}))
        .assertCreated()
        .assertJsonPath('data.title', 'Hello');
    await assertDatabaseHas('posts', {'title': 'Hello'});
  });
}
```

- `TestClient` with `actingAs`, `withToken`, `withHeaders`,
  `withoutExceptionHandling`, and fluent `TestResponse` assertions.
- `refreshDatabase`, `assertDatabaseHas` / `Missing` / `Count`.
- Time travel (`freezeTime`, `travel`, `travelTo`) over Daravel's `Clock`.
- Architecture checks (`expectRegistryComplete`) and lint integration.
- `package:daravel_test/conformance.dart`: Laravel 12 wire-format contracts
  (`isLaravelValidationError`, `isLaravelErrorBody`,
  `isLaravelLengthAwarePaginator`, Sanctum token format, ...) to prove your
  API still speaks Laravel.

See [`example/main.dart`](example/main.dart) and the
[testing guide](https://github.com/daravel-dev/daravel/blob/main/docs/guide/testing.md).

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC. Daravel is an independent project, not affiliated
with or endorsed by either.
