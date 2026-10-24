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

  const ana = <String, Object?>{
    'name': 'Ana',
    'email': 'ana@example.com',
    'password': 'secret-123',
    'password_confirmation': 'secret-123',
  };

  Future<String> register([Map<String, Object?> payload = ana]) async {
    final response = (await client.post('/api/auth/register', json: payload))
        .assertCreated()
        .assertJsonPath('user.email', payload['email'])
        .assertJsonPath('token_type', 'Bearer');
    return (response.json as Map<String, Object?>)['token'] as String;
  }

  test('register → me → logout → 401', () async {
    final token = await register();
    // Sanctum 4 format: id|40 random chars + crc32b checksum.
    expect(token, matches(RegExp(r'^\d+\|[A-Za-z0-9]{40}[0-9a-f]{8}$')));
    (await client.get('/api/auth/me'))
        .assertUnauthorized()
        .assertJsonPath('message', 'Unauthenticated.');
    (await client.withToken(token).get('/api/auth/me'))
        .assertOk()
        .assertJsonPath('data.email', 'ana@example.com')
        .assertJsonPath('data.password', null);
    (await client.withToken(token).post('/api/auth/logout')).assertNoContent();
    (await client.withToken(token).get('/api/auth/me')).assertUnauthorized();
  });

  test('login validates credentials and never leaks the hash', () async {
    await register();
    (await client.post(
      '/api/auth/login',
      json: {'email': 'ana@example.com', 'password': 'wrong'},
    )).assertUnprocessable().assertJsonPath(
      'errors.email.0',
      'These credentials do not match our records.',
    );
    final login = (await client.post(
      '/api/auth/login',
      json: {
        'email': 'ana@example.com',
        'password': 'secret-123',
        'device_name': 'phone',
      },
    )).assertOk().assertJsonPath('user.name', 'Ana');
    final token = (login.json as Map<String, Object?>)['token'] as String;
    (await client.withToken(token).get('/api/auth/me')).assertOk();
    await app.run(() async {
      final stored = await DB
          .table('users')
          .where('email', 'ana@example.com')
          .first();
      expect(
        Hash.info(stored!['password']! as String).driver,
        HashDriver.argon2id,
      );
      final tokens = await DB.table('personal_access_tokens').get();
      expect(tokens.map((t) => t['name']), containsAll(['api', 'phone']));
    });
  });

  test('login is throttled per email + ip (5 per minute)', () async {
    for (var i = 0; i < 5; i++) {
      (await client.post(
        '/api/auth/login',
        json: {'email': 'ana@example.com', 'password': 'wrong'},
      )).assertUnprocessable();
    }
    (await client.post(
          '/api/auth/login',
          json: {'email': 'ana@example.com', 'password': 'wrong'},
        ))
        .assertStatus(429)
        .assertHeader('retry-after')
        .assertJsonPath('message', 'Too Many Attempts.');
    // Another email is not affected.
    (await client.post(
      '/api/auth/login',
      json: {'email': 'bo@example.com', 'password': 'wrong'},
    )).assertUnprocessable();
  });

  test('policies: users may only update their own profile', () async {
    final anaToken = await register();
    final boToken = await register({
      'name': 'Bo',
      'email': 'bo@example.com',
      'password': 'secret-123',
      'password_confirmation': 'secret-123',
    });
    (await client.patch(
      '/api/users/1',
      json: {'name': 'Nobody'},
    )).assertUnauthorized();
    (await client
            .withToken(anaToken)
            .patch('/api/users/1', json: {'name': 'Ana B.'}))
        .assertOk()
        .assertJsonPath('data.name', 'Ana B.');
    (await client
            .withToken(boToken)
            .patch('/api/users/1', json: {'name': 'Hacked'}))
        .assertForbidden()
        .assertJsonPath('message', 'You may only update your own profile.');
    (await client
            .withToken(boToken)
            .patch('/api/users/99', json: {'name': 'x'}))
        .assertNotFound();
  });
}
