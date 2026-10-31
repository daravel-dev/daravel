import 'dart:io';

import 'package:daravel_test/daravel_test.dart';

import '../../bootstrap/app.dart';

/// One app per file, migrated once; every test is rolled back.
void main() {
  final db = refreshDatabase(
    () => createApp(
      basePath: Directory.current.path,
      env: <String, String>{
        'APP_ENV': 'testing',
        'DB_CONNECTION': 'sqlite',
        'DB_URL': 'sqlite::memory:',
      },
    ),
  );

  const ana = <String, Object?>{
    'name': 'Ana',
    'email': 'ana@example.com',
    'password': 'secret-123',
    'password_confirmation': 'secret-123',
  };

  db.test('registering stores the user and queues the welcome email', () async {
    (await db.client.post(
      '/api/auth/register',
      json: ana,
    )).assertCreated().assertJsonStructure(<String, Object>{
      'user': ['id', 'name', 'email'],
      'token': <String>[],
    });
    await assertDatabaseHas('users', {'email': 'ana@example.com'});
    await assertDatabaseCount('personal_access_tokens', 1);
  });

  db.test(
    'the same email can register again: the previous test rolled back',
    () async {
      await assertDatabaseEmpty('users');
      (await db.client.post('/api/auth/register', json: ana)).assertCreated();
    },
  );

  db.test('validation errors are reported per field', () async {
    (await db.client.post(
      '/api/auth/register',
      json: {'email': 'nope'},
    )).assertInvalid(['name', 'email', 'password']);
  });
}
