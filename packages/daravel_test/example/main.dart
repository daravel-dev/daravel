import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/conformance.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

Application createApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withRouting(
          apiPrefix: '/api',
          api: (router) {
            router.get('/ping', (_) => {'ok': true});
            router.post('/users', (request) async {
              final data = await request.validate({'email': 'required|email'});
              return Response.created(data.toMap());
            });
          },
        )
        .create();

/// Feature tests with `TestClient` and Laravel conformance matchers.
/// Run with `dart test example/main.dart`.
void main() {
  late Application app;
  late TestClient client;

  setUp(() async {
    app = createApp();
    await app.boot();
    client = TestClient(app);
  });
  tearDown(() => app.shutdown());

  test('ping', () async {
    (await client.get('/api/ping')).assertOk().assertExactJson({'ok': true});
  });

  test('validation errors use Laravel 422 bodies', () async {
    final response = await client.post('/api/users', json: {'email': 'nope'});
    response.assertUnprocessable();
    expect(
      response.json,
      isLaravelValidationError({
        'email': ['The email field must be a valid email address.'],
      }),
    );
  });
}
