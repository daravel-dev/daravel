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

  group('schemas other than the current one', () {
    DatabaseManager manager([Map<String, Object?> options = const {}]) =>
        DatabaseManager(
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
                options: {'pool': 2, 'sslmode': 'disable', ...options},
              ),
            },
          ),
        );

    setUp(() async {
      final admin = manager();
      await admin.statement('DROP SCHEMA IF EXISTS daravel_hr CASCADE');
      await admin.statement('CREATE SCHEMA daravel_hr');
      await admin.statement(
        'CREATE TABLE daravel_hr.staff (id INT PRIMARY KEY, name TEXT NOT NULL)',
      );
      await admin.statement(
        'CREATE TABLE daravel_hr.answers (id INT, exam INT) PARTITION BY LIST (exam)',
      );
      await admin.statement(
        'CREATE VIEW daravel_hr.staff_names AS SELECT name FROM daravel_hr.staff',
      );
      await admin.statement(
        'CREATE MATERIALIZED VIEW daravel_hr.staff_count AS SELECT count(*) AS total FROM daravel_hr.staff',
      );
      await admin.closeAll();
    });

    tearDown(() async {
      final admin = manager();
      await admin.statement('DROP SCHEMA IF EXISTS daravel_hr CASCADE');
      await admin.closeAll();
    });

    test('schema.table, views and partitioned tables are seen', () async {
      final admin = manager();
      addTearDown(admin.closeAll);
      final schema = SchemaBuilder(await admin.executor());
      expect(await schema.hasTable('daravel_hr.staff'), isTrue);
      expect(await schema.hasTable('daravel_hr.answers'), isTrue);
      expect(await schema.hasTable('staff'), isFalse);
      expect(await schema.hasTable('daravel_hr.nope'), isFalse);
      expect(await schema.hasTable('daravel_hr.staff_names'), isFalse);
      expect(await schema.hasView('daravel_hr.staff_names'), isTrue);
      expect(await schema.hasView('daravel_hr.staff_count'), isTrue);
      expect(await schema.hasView('daravel_hr.staff'), isFalse);
      expect((await schema.getColumns('daravel_hr.staff')).map((c) => c.name), [
        'id',
        'name',
      ]);
      expect(
        (await schema.getColumns('daravel_hr.staff_names')).single.name,
        'name',
      );
      expect(() => schema.hasTable('a.b.c'), throwsArgumentError);
    });

    test('uncast dates reach JSON as PDO text, in every type', () async {
      final admin = manager();
      addTearDown(admin.closeAll);
      await admin.statement('''
        CREATE TABLE daravel_hr.moments (
          day DATE, at TIMESTAMP(6), at_zone TIMESTAMPTZ, empty TIMESTAMP
        )''');
      await admin.statement('''
        INSERT INTO daravel_hr.moments VALUES (
          '2024-01-02', '2024-01-02 10:20:30.5', '2024-01-02 10:20:30+00', NULL
        )''');
      final row = (await admin.select('SELECT * FROM daravel_hr.moments'))
          .single;
      expect(row['day'], isA<DateTime>());
      expect(row['empty'], isNull);
      expect(Response.json(row).bodyBytes, isNotNull);
      expect(jsonDate(row['day']! as DateTime), '2024-01-02');
      expect(jsonDate(row['at']! as DateTime), '2024-01-02 10:20:30.5');
      expect(jsonDate(row['at_zone']! as DateTime), '2024-01-02 10:20:30+00');
    });

    test('search_path applies to every connection of the pool', () async {
      final scoped = manager({'search_path': 'daravel_hr, public'});
      addTearDown(scoped.closeAll);
      final schema = SchemaBuilder(await scoped.executor());
      expect(await schema.hasTable('staff'), isTrue);
      final rows = await Future.wait([
        for (var i = 0; i < 4; i++)
          scoped.select('SELECT current_schema() AS s, pg_sleep(0.05)'),
      ]);
      expect(rows.map((r) => r.single['s']).toSet(), {'daravel_hr'});
    });
  });

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

  test('non-finite doubles round-trip as PostgreSQL reads them', () async {
    final schema = SchemaBuilder(await db.executor());
    await schema.dropIfExists('pg_floats');
    await schema.create('pg_floats', (t) {
      t.id();
      t.doublePrecision('v');
    });
    try {
      for (final v in [double.infinity, double.negativeInfinity, double.nan]) {
        await db.table('pg_floats').insert({'v': v});
      }
      final values = [
        for (final row in await db.table('pg_floats').orderBy('id').get())
          row['v'],
      ];
      expect(values[0], double.infinity);
      expect(values[1], double.negativeInfinity);
      expect(values[2], isA<double>().having((d) => d.isNaN, 'isNaN', isTrue));
    } finally {
      await schema.dropIfExists('pg_floats');
    }
  });
  test('a duplicate is a UniqueConstraintViolationException', () async {
    await db.table('pg_items').insert({'name': 'dup'});
    await expectLater(
      db.table('pg_items').insert({'name': 'dup'}),
      throwsA(
        isA<UniqueConstraintViolationException>()
            .having((e) => e.connectionName, 'connection', 'pgsql')
            .having(
              (e) => '${e.previous.runtimeType}',
              'driver error',
              contains('UniqueViolation'),
            ),
      ),
    );
    await expectLater(
      db.table('pg_items_missing').get(),
      throwsA(
        isA<QueryException>().having(
          (e) => e,
          'type',
          isNot(isA<UniqueConstraintViolationException>()),
        ),
      ),
    );
  });

  test(
    'createOrFirst keeps the transaction usable; firstOrCreate races',
    () async {
      final items = _Item.definition;
      await db.transaction(() async {
        await items.query(db: db).create({'name': 'kept'});
        // Refused by the unique index inside the transaction: a savepoint, so
        // the transaction is not aborted and commits.
        final again = await items.query(db: db).createOrFirst({'name': 'kept'});
        expect(again.wasRecentlyCreated, isFalse);
        await items.query(db: db).create({'name': 'after'});
      });
      expect(await db.table('pg_items').count(), 2);

      final racers = await Future.wait([
        for (var i = 0; i < 12; i++)
          items.query(db: db).firstOrCreate({'name': 'race'}, {'qty': i}),
      ]);
      expect({for (final r in racers) r.attributes['id']}, hasLength(1));
      expect(await db.table('pg_items').where('name', 'race').count(), 1);
    },
  );
}

final class _Item extends Model {
  static final ModelDefinition<_Item> definition = ModelDefinition<_Item>(
    table: 'pg_items',
    factory: _Item.new,
    guarded: [],
  );

  @override
  ModelDefinition<_Item> get modelDefinition => _Item.definition;
}
