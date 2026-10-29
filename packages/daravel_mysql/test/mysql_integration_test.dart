@Tags(['integration'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:test/test.dart';

/// Runs only when `DARAVEL_TEST_MYSQL` is set, e.g.
/// `DARAVEL_TEST_MYSQL=mysql://daravel:secret@127.0.0.1:3306/daravel_test`.
/// CI runs it against MySQL 8.4 and MariaDB 11.
void main() {
  final url = Platform.environment['DARAVEL_TEST_MYSQL'];
  if (url == null || url.isEmpty) {
    test(
      'mysql integration (skipped: DARAVEL_TEST_MYSQL not set)',
      () {},
      skip: true,
    );
    return;
  }
  final uri = Uri.parse(url);
  final user = uri.userInfo.split(':');
  final connection = ConnectionConfig(
    driver: 'mysql',
    database: uri.path.replaceFirst('/', ''),
    host: uri.host,
    port: uri.hasPort ? uri.port : 3306,
    username: user.first,
    password: user.length > 1 ? Uri.decodeComponent(user[1]) : null,
    options: const {'pool': 4},
  );

  late DatabaseManager db;

  setUp(() async {
    db = DatabaseManager(
      DatabaseConfig(
        defaultConnection: 'mysql',
        connections: {'mysql': connection},
      ),
      drivers: const {'mysql': MySqlDriver.fromConfig},
    );
    final schema = SchemaBuilder(await db.executor());
    for (final table in ['my_items', 'my_tags']) {
      await schema.dropIfExists(table);
    }
    await schema.create('my_items', (t) {
      t.id();
      t.string('name').unique();
      t.integer('qty').defaultTo(0);
      t.boolean('active').defaultTo(true);
      t.decimal('price', precision: 8, scale: 2).nullable();
      t.json('tags').nullable();
      t.text('note').nullable();
      t.dateTime('seen_at').nullable();
      t.timestamps();
    });
  });

  tearDown(() async {
    final schema = SchemaBuilder(await db.executor());
    for (final table in ['my_items', 'my_tags']) {
      await schema.dropIfExists(table);
    }
    await db.closeAll();
  });

  test('CRUD, ids, upsert, named bindings and value types', () async {
    final id = await db.table('my_items').insertGetId({
      'name': 'a',
      'qty': 1,
      'active': false,
      'price': 9.5,
      'tags': '["x", "y"]',
      'note': 'naïve 🐉',
      'seen_at': DateTime.utc(2026, 1, 2, 3, 4, 5),
    });
    expect(id, 1);
    await db.table('my_items').upsert({'name': 'a', 'qty': 5}, ['name'], [
      'qty',
    ]);
    final row = await db.table('my_items').where('name', 'a').sole();
    expect(row['qty'], 5);
    expect(row['active'], 0, reason: 'booleans are TINYINT(1), as in Laravel');
    expect(row['note'], 'naïve 🐉', reason: 'utf8mb4');
    expect(row['seen_at'], '2026-01-02 03:04:05', reason: "Laravel's format");
    expect(
      await db.select('SELECT qty FROM my_items WHERE name = :n', {'n': 'a'}),
      [
        {'qty': 5},
      ],
    );
    expect(
      await db.table('my_items').whereJsonLength('tags', '>', 1).count(),
      1,
    );
    expect(
      await db.table('my_items').where('name', "a' OR 1=1 -- ").count(),
      0,
      reason: 'bindings never reach the SQL text',
    );
  });

  test('transactions roll back; nested ones are savepoints', () async {
    await db.transaction(() async {
      await db.table('my_items').insert({'name': 'b'});
      await expectLater(
        db.transaction(() async {
          await db.table('my_items').insert({'name': 'c'});
          throw StateError('rollback c');
        }),
        throwsStateError,
      );
    });
    await expectLater(
      db.transaction(() async {
        await db.table('my_items').insert({'name': 'd'});
        throw StateError('rollback all');
      }),
      throwsStateError,
    );
    expect(await db.table('my_items').orderBy('id').pluck('name'), ['b']);
    final page = await db.table('my_items').paginate(perPage: 10);
    expect(page.total, 1);
    await db.table('my_items').truncate();
    expect(await db.table('my_items').count(), 0);
  });

  test('schema introspection', () async {
    final schema = SchemaBuilder(await db.executor());
    expect(await schema.hasTable('my_items'), isTrue);
    expect(await schema.hasTable('nope'), isFalse);
    expect(await schema.getTables(), contains('my_items'));
    final columns = {
      for (final c in await schema.getColumns('my_items')) c.name: c,
    };
    expect(columns['id']!.autoIncrement, isTrue);
    expect(columns['id']!.primary, isTrue);
    expect(columns['note']!.nullable, isTrue);
    expect(columns['name']!.nullable, isFalse);
    await schema.table('my_items', (t) => t.string('extra').nullable());
    expect(await schema.hasColumn('my_items', 'extra'), isTrue);
  });

  test('framework migrations create Laravel\'s shared tables', () async {
    final tables = [
      'cache',
      'cache_locks',
      'jobs',
      'job_batches',
      'failed_jobs',
      'personal_access_tokens',
      'migrations',
    ];
    final schema = SchemaBuilder(await db.executor());
    for (final table in tables) {
      await schema.dropIfExists(table);
    }
    final migrator = Migrator(db, const [
      CreateCacheTable(),
      CreateJobsTable(),
      CreatePersonalAccessTokensTable(),
    ]);
    final ran = await migrator.run();
    expect(ran, hasLength(3));
    for (final table in tables) {
      expect(await schema.hasTable(table), isTrue, reason: table);
    }
    await migrator.reset();
    for (final table in tables.where((t) => t != 'migrations')) {
      expect(await schema.hasTable(table), isFalse, reason: table);
    }
    await schema.dropIfExists('migrations');
  });

  test('an application uses the driver through withDatabaseDriver', () async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'mysql',
          'DB_HOST': connection.host!,
          'DB_PORT': '${connection.port}',
          'DB_DATABASE': connection.database,
          'DB_USERNAME': connection.username ?? '',
          'DB_PASSWORD': connection.password ?? '',
        })
        .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    await app.run(() async {
      expect(DB.manager.dialectOf(), SqlDialect.mysql);
      expect(await DB.table('my_items').count(), 0);
    });
  });
  test('a duplicate is a UniqueConstraintViolationException', () async {
    await db.table('my_items').insert({'name': 'dup'});
    await expectLater(
      db.table('my_items').insert({'name': 'dup'}),
      throwsA(
        isA<UniqueConstraintViolationException>()
            .having((e) => e.connectionName, 'connection', 'mysql')
            .having(
              (e) => '${e.previous.runtimeType}',
              'driver error',
              contains('MySQLServerException'),
            ),
      ),
    );
    await expectLater(
      db.table('my_items_missing').get(),
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
      expect(await db.table('my_items').count(), 2);

      final racers = await Future.wait([
        for (var i = 0; i < 12; i++)
          items.query(db: db).firstOrCreate({'name': 'race'}, {'qty': i}),
      ]);
      expect({for (final r in racers) r.attributes['id']}, hasLength(1));
      expect(await db.table('my_items').where('name', 'race').count(), 1);
    },
  );

  test(
    "DB_STRICT as Laravel's 'strict': legacy inserts and the mode",
    () async {
      Future<(String, Object?)> run(String? strict) async {
        final manager = DatabaseManager(
          DatabaseConfig(
            defaultConnection: 'mysql',
            connections: {
              'mysql': ConnectionConfig(
                driver: 'mysql',
                database: connection.database,
                host: connection.host,
                port: connection.port,
                username: connection.username,
                password: connection.password,
                options: {'pool': 1, 'strict': strict},
              ),
            },
          ),
          drivers: const {'mysql': MySqlDriver.fromConfig},
        );
        try {
          final mode =
              (await manager.select('SELECT @@SESSION.sql_mode AS m'))
                      .first['m']
                  as String;
          await manager.statement('DROP TABLE IF EXISTS my_legacy');
          await manager.statement(
            'CREATE TABLE my_legacy (id INT AUTO_INCREMENT PRIMARY KEY, '
            'name VARCHAR(20) NOT NULL, merchant_id INT NOT NULL)',
          );
          Object? error;
          try {
            // merchant_id has no value and no default: what a Laravel 8
            // application with 'strict' => false relies on.
            await manager.statement(
              "INSERT INTO my_legacy (name) VALUES ('a')",
            );
          } on Object catch (e) {
            error = e;
          }
          await manager.statement('DROP TABLE my_legacy');
          return (mode, error);
        } finally {
          await manager.closeAll();
        }
      }

      final (loose, looseError) = await run('false');
      expect(loose, 'NO_ENGINE_SUBSTITUTION');
      expect(looseError, isNull, reason: 'merchant_id becomes 0');

      final (strict, strictError) = await run('true');
      expect(strict, contains('STRICT_TRANS_TABLES'));
      expect(strict, contains('ONLY_FULL_GROUP_BY'));
      expect(
        strictError,
        isNotNull,
        reason: "Field 'merchant_id' doesn't have a default value",
      );
    },
  );
}

final class _Item extends Model {
  static final ModelDefinition<_Item> definition = ModelDefinition<_Item>(
    table: 'my_items',
    factory: _Item.new,
    guarded: [],
  );

  @override
  ModelDefinition<_Item> get modelDefinition => _Item.definition;
}
