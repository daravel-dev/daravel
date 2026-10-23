import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import '../../bootstrap/app.dart';

void main() {
  late Application app;
  late TestClient client;

  setUp(() async {
    app = createApp(
      basePath: Directory.current.path,
      env: <String, String>{'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'},
    );
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
    client = TestClient(app);
  });

  tearDown(() => app.shutdown());

  const valid = <String, Object?>{
    'name': 'Ana',
    'email': 'ana@example.com',
    'password': 'secret123',
    'password_confirmation': 'secret123',
  };

  test(
    'POST /api/users validates input with Laravel-style 422 responses',
    () async {
      (await client.post(
            '/api/users',
            json: <String, Object?>{'email': 'nope', 'password': 'short'},
          ))
          .assertUnprocessable()
          .assertJsonPath('errors.name.0', 'The name field is required.')
          .assertJsonPath(
            'errors.email.0',
            'The email address field must be a valid email address.',
          )
          .assertJsonPath(
            'errors.password.0',
            'The password field must be at least 8 characters.',
          )
          .assertJsonPath(
            'message',
            'The name field is required. (and 3 more errors)',
          );
    },
  );

  test('POST /api/users creates a user and rejects duplicate emails', () async {
    (await client.post('/api/users', json: valid))
        .assertCreated()
        .assertJsonPath('data.id', 1)
        .assertJsonPath('data.email', 'ana@example.com');

    (await client.get(
      '/api/users/1',
    )).assertOk().assertJsonPath('data.name', 'Ana');

    (await client.post(
      '/api/users',
      json: valid,
    )).assertUnprocessable().assertJsonPath(
      'errors.email.0',
      'The email address has already been taken.',
    );
  });

  test(
    'GET /api/users returns a resource collection with links and meta',
    () async {
      (await client.post('/api/users', json: valid)).assertCreated();
      (await client.get('/api/users'))
          .assertOk()
          .assertJsonPath('data.0.email', 'ana@example.com')
          .assertJsonPath('data.0.email_verified', false)
          .assertJsonPath('data.0.password', null)
          .assertJsonPath('links.first', '/api/users?page=1')
          .assertJsonPath('links.next', null)
          .assertJsonPath('meta.total', 1)
          .assertJsonPath('meta.per_page', 15);
    },
  );
}
