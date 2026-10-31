@Tags(['conformance'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/conformance.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import '../../bootstrap/app.dart';

/// Verifies that this application's API still speaks Laravel's wire format
/// (BLUEPRINT_V2 §11.2), so a Laravel client or a Laravel app sharing the
/// database keeps working. Run with `dart test --tags conformance`.
void main() {
  late Application app;
  late TestClient client;

  setUp(() async {
    app = createApp(
      basePath: Directory.current.path,
      env: <String, String>{
        'APP_ENV': 'testing',
        'DB_CONNECTION': 'sqlite',
        'DB_URL': 'sqlite::memory:',
      },
    );
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
    client = TestClient(app);
  });

  tearDown(() => app.shutdown());

  const ana = <String, Object?>{
    'name': 'Ana',
    'email': 'ana@example.com',
    'password': 'secret-123',
    'password_confirmation': 'secret-123',
  };

  test('422 bodies are Laravel validation errors', () async {
    final res = await client.post('/api/users', json: <String, Object?>{});
    res.assertUnprocessable();
    expect(res.json, isLaravelValidationError());
  });

  test('unknown routes and guarded routes use Laravel messages', () async {
    expect(
      (await client.get('/api/nope')).json,
      isLaravelErrorBody(LaravelContract.routeNotFound('api/nope')),
    );
    expect(
      (await client.get('/api/auth/me')).json,
      isLaravelErrorBody(LaravelContract.unauthenticated),
    );
  });

  test('tokens are Sanctum 4 tokens', () async {
    final res = await client.post('/api/auth/register', json: ana);
    expect(
      res.jsonMap['token'],
      matches(LaravelContract.sanctumPlainTextToken),
    );
  });

  test('the users index is a Laravel paginated resource', () async {
    (await client.post('/api/users', json: ana)).assertCreated();
    final res = await client.get('/api/users');
    expect(res.jsonMap.keys, ['data', 'links', 'meta']);
    final meta = res.jsonMap['meta']! as Map<String, Object?>;
    expect(meta['path'], 'http://localhost/api/users');
    final data = res.jsonMap['data']! as List<Object?>;
    final user = data.single! as Map<String, Object?>;
    expect(user['created_at'], matches(LaravelContract.jsonDate));
  });
}
