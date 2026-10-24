@Tags(['integration'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Runs only when `DARAVEL_TEST_PG` is set, e.g.
/// `DARAVEL_TEST_PG=postgres://daravel:secret@127.0.0.1:5432/daravel_test`.
/// CI provides a PostgreSQL service container; locally start one with
/// `docker run -e POSTGRES_USER=daravel -e POSTGRES_PASSWORD=secret
/// -e POSTGRES_DB=daravel_test -p 5432:5432 postgres:16`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_PG'];
  if (url == null || url.isEmpty) {
    test(
      'postgres integration (skipped: DARAVEL_TEST_PG not set)',
      () {},
      skip: true,
    );
    return;
  }
  final uri = Uri.parse(url);
  final userInfo = uri.userInfo.split(':');

  late DatabaseManager db;

  setUp(() async {
    db = DatabaseManager(
      DatabaseConfig(
        defaultConnection: 'pgsql',
        connections: {
          'pgsql': ConnectionConfig(
            driver: 'pgsql',
            database: uri.path.replaceFirst('/', ''),
            host: uri.host,
            port: uri.hasPort ? uri.port : 5432,
            username: userInfo.first,
            password: userInfo.length > 1 ? userInfo[1] : null,
            options: const {'pool': 4, 'sslmode': 'disable'},
          ),
        },
      ),
    );
    final schema = SchemaBuilder(await db.executor());
    await schema.dropIfExists('pg_items');
    await schema.create('pg_items', (t) {
      t.id();
      t.string('name').unique();
      t.integer('qty').defaultTo(0);
      t.boolean('active').defaultTo(true);
      t.json('tags').nullable();
      t.timestamps();
    });
  });

  tearDown(() async {
    await SchemaBuilder(await db.executor()).dropIfExists('pg_items');
    await db.closeAll();
  });

  test('CRUD, RETURNING ids, upsert, named bindings and savepoints', () async {
    final id = await db.table('pg_items').insertGetId({
      'name': 'a',
      'qty': 1,
      'tags': '["x", "y"]',
    });
    expect(id, 1);
    await db.table('pg_items').upsert({'name': 'a', 'qty': 5}, ['name'], [
      'qty',
    ]);
    expect((await db.table('pg_items').where('name', 'a').sole())['qty'], 5);
    expect(
      await db.select('SELECT qty FROM pg_items WHERE name = :n', {'n': 'a'}),
      [
        {'qty': 5},
      ],
    );
    expect(
      await db.table('pg_items').whereJsonLength('tags', '>', 1).count(),
      1,
    );

    await db.transaction(() async {
      await db.table('pg_items').insert({'name': 'b'});
      await expectLater(
        db.transaction(() async {
          await db.table('pg_items').insert({'name': 'c'});
          throw StateError('rollback c');
        }),
        throwsStateError,
      );
    });
    expect(await db.table('pg_items').orderBy('id').pluck('name'), ['a', 'b']);
    expect(await db.table('pg_items').count(), 2);
    await db.table('pg_items').truncate();
    expect(await db.table('pg_items').count(), 0);
  });
}
