# Testing

`package:daravel_test` drives your application without opening sockets:

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

- `TestClient(app)` with `actingAs(user)`, `withToken(token)`,
  `withHeaders`, `withoutExceptionHandling()`.
- `TestResponse` assertions: status helpers, `assertJson`,
  `assertExactJson`, `assertJsonPath`, `assertJsonStructure`,
  `assertJsonValidationErrors`, headers.
- `refreshDatabase(createApp)` runs each test in a transaction that is
  rolled back (Laravel's `RefreshDatabase`); `assertDatabaseHas` /
  `assertDatabaseMissing` / `assertDatabaseCount`.
- Fakes: `Event.fake()`, `Queue.fake()`, `Storage.fake()`, with
  `assertDispatched`, `assertPushed`, ...
- Time: `freezeTime()`, `travel(duration)`, `travelTo(time)`; domain time
  reads `Clock.now()`.
- Architecture: `expectRegistryComplete()` and lints via `dartisan lint`.

Run the suite with `dartisan test` (`--coverage` writes `coverage/`).

## Conformance tests

`package:daravel_test/conformance.dart` exposes Laravel 12's wire contracts
as matchers, so an application can prove it still speaks Laravel:

```dart
import 'package:daravel_test/conformance.dart';

expect(response.json, isLaravelValidationError({'email': ['The email field is required.']}));
expect(response.json, isLaravelErrorBody(LaravelContract.unauthenticated));
expect(token, matches(LaravelContract.sanctumPlainTextToken));
expect(body, isLaravelLengthAwarePaginator());
```

New projects include `test/conformance/` and `dart_test.yaml`; run them with
`dartisan test --conformance`.
