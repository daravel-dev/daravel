import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import '../../bootstrap/app.dart';

void main() {
  late Application app;

  setUp(() async {
    app = createApp(
      basePath: Directory.current.path,
      env: <String, String>{'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'},
    );
    await app.boot();
  });

  tearDown(() => app.shutdown());

  test('users migration runs, serves data and rolls back', () async {
    await app.run(() async {
      final migrator = App.make<Migrator>();
      expect(
        await migrator.run(),
        unorderedEquals(<String>[
          '0001_01_01_000001_create_cache_table',
          '0001_01_01_000002_create_jobs_table',
          '2019_12_14_000001_create_personal_access_tokens_table',
          '2026_10_23_000001_create_users_table',
        ]),
      );
      expect((await migrator.status()).every((m) => m.ran), isTrue);

      final id = await DB.insertGetId(
        'INSERT INTO "users" ("name", "email", "password") VALUES (?, ?, ?)',
        <Object?>['Ana', 'ana@example.com', 'hash'],
      );
      expect(id, 1);

      await expectLater(
        DB.statement(
          'INSERT INTO "users" ("name", "email", "password") VALUES (?, ?, ?)',
          <Object?>['Dup', 'ana@example.com', 'hash'],
        ),
        throwsA(anything),
        reason: 'email must be unique',
      );
    });

    final client = TestClient(app);
    (await client.get('/api/users/1'))
        .assertOk()
        .assertJsonPath('data.name', 'Ana')
        .assertJsonPath('data.email', 'ana@example.com');
    (await client.get(
      '/api/users/2',
    )).assertNotFound().assertJsonPath('message', 'User [2] not found.');

    await app.run(() async {
      expect(await App.make<Migrator>().rollback(), hasLength(4));
      expect(await Schema.hasTable('users'), isFalse);
    });
  });
}
