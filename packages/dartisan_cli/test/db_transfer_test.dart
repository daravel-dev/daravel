import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const List<String> tables = ['xfer_posts', 'xfer_categories', 'xfer_users'];

final class CreateTransferTables extends Migration {
  const CreateTransferTables();
  @override
  String get name => '2026_10_26_000000_create_xfer_tables';
  @override
  Future<void> up(SchemaBuilder schema) async {
    await schema.create('xfer_users', (t) {
      t.id();
      t.string('name');
      t.boolean('active');
      t.json('meta').nullable();
      t.timestamp('created_at').nullable();
    });
    await schema.create('xfer_posts', (t) {
      t.id();
      t.foreignId('user_id').constrained('xfer_users');
      t.string('title');
    });
    await schema.create('xfer_categories', (t) {
      t.id();
      final parent = t.foreignId('parent_id');
      parent.nullable();
      parent.constrained('xfer_categories');
      t.string('name');
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    for (final table in tables) {
      await schema.dropIfExists(table);
    }
  }
}

const List<Migration> migrations = [CreateTransferTables()];

DatabaseManager manager(ConnectionConfig connection) => DatabaseManager(
  DatabaseConfig(defaultConnection: 'main', connections: {'main': connection}),
  drivers: const {
    'mysql': MySqlDriver.fromConfig,
    'mariadb': MySqlDriver.fromConfig,
  },
);

/// A SQLite source with users, posts referencing them and categories
/// referencing each other (category 3's parent, 5, comes later).
Future<DatabaseManager> seededSource(String path) async {
  final db = manager(ConnectionConfig(driver: 'sqlite', database: path));
  await Migrator(db, migrations).run();
  await db.table('xfer_users').insert([
    {
      'id': 1,
      'name': 'Teo',
      'active': true,
      'meta': jsonEncode({'role': 'admin'}),
      'created_at': '2026-10-26 08:00:00',
    },
    {'id': 2, 'name': 'Ana', 'active': false, 'meta': null, 'created_at': null},
    {
      'id': 7,
      'name': 'Budi',
      'active': true,
      'meta': '[1,2]',
      'created_at': '2026-01-02 03:04:05',
    },
  ]);
  await db.table('xfer_posts').insert([
    {'id': 1, 'user_id': 7, 'title': 'First'},
    {'id': 2, 'user_id': 1, 'title': 'Second'},
  ]);
  await db.table('xfer_categories').insert([
    {'id': 1, 'parent_id': null, 'name': 'Root'},
    {'id': 3, 'parent_id': 5, 'name': 'Late child'},
    {'id': 5, 'parent_id': 1, 'name': 'Parent'},
  ]);
  return db;
}

/// Drops the transfer tables and the ledger rows of a shared test database.
Future<void> reset(DatabaseManager db) async {
  final schema = SchemaBuilder(await db.executor());
  for (final table in tables) {
    await schema.dropIfExists(table);
  }
  if (await schema.hasTable('migrations')) {
    await db
        .table('migrations')
        .where('migration', CreateTransferTables().name)
        .delete();
  }
}

ConnectionConfig fromUrl(String url) => connectionFromSpec(
  url,
  const DatabaseConfig(defaultConnection: 'x', connections: {}),
  basePath: '.',
);

void main() {
  group('connectionFromSpec', () {
    const config = DatabaseConfig(
      defaultConnection: 'sqlite',
      connections: {
        'sqlite': ConnectionConfig(
          driver: 'sqlite',
          database: '/app/db.sqlite',
        ),
      },
    );

    test('configured names, sqlite paths and URLs', () {
      expect(
        connectionFromSpec('sqlite', config, basePath: '/app').database,
        '/app/db.sqlite',
      );
      expect(
        connectionFromSpec(
          'sqlite:old.sqlite',
          config,
          basePath: '/app',
        ).database,
        p.join('/app', 'old.sqlite'),
      );
      expect(
        connectionFromSpec(
          'sqlite::memory:',
          config,
          basePath: '/app',
        ).database,
        ':memory:',
      );
      final pg = connectionFromSpec(
        'postgres://shop:s%40cret@db.internal:6432/shop?sslmode=require',
        config,
        basePath: '/app',
      );
      expect(pg.driver, 'pgsql');
      expect(pg.host, 'db.internal');
      expect(pg.port, 6432);
      expect(pg.database, 'shop');
      expect(pg.username, 'shop');
      expect(pg.password, 's@cret');
      expect(pg.options['sslmode'], 'require');
      final my = connectionFromSpec(
        'mysql://root@localhost/shop',
        config,
        basePath: '/app',
      );
      expect((my.driver, my.port, my.password), ('mysql', 3306, null));
      expect(describeConnection(pg), 'pgsql://db.internal:6432/shop');
    });

    test('unknown specs explain the accepted forms', () {
      expect(
        () => connectionFromSpec('oracle://x/y', config, basePath: '/'),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => connectionFromSpec('pgsql://host', config, basePath: '/'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('adaptValue', () {
    test('documents, booleans and dates follow the target', () {
      expect(adaptValue({'a': 1}, 'jsonb', SqlDialect.postgres), '{"a":1}');
      expect(adaptValue(0, 'boolean', SqlDialect.postgres), false);
      expect(adaptValue('1', 'boolean', SqlDialect.postgres), true);
      expect(adaptValue(1, 'integer', SqlDialect.postgres), 1);
      final when = DateTime.utc(2026, 10, 26, 8, 30, 5);
      expect(
        adaptValue(when, 'datetime', SqlDialect.sqlite),
        '2026-10-26 08:30:05',
      );
      expect(adaptValue(when, 'date', SqlDialect.mysql), '2026-10-26');
      expect(adaptValue(null, 'boolean', SqlDialect.postgres), isNull);
    });
  });

  late Directory dir;
  setUp(() async => dir = await Directory.systemTemp.createTemp('xfer_'));
  tearDown(() async {
    try {
      await dir.delete(recursive: true);
    } on FileSystemException {
      // Windows may still hold the database file briefly.
    }
  });

  /// Copies the seeded source into [target] and checks every row.
  Future<void> transferInto(DatabaseManager target) async {
    final source = await seededSource(p.join(dir.path, 'source.sqlite'));
    addTearDown(source.closeAll);
    final report = await DatabaseTransfer(
      source: source,
      target: target,
      migrations: migrations,
      chunk: 2, // several pages per table
    ).run();
    expect(report.migrated, [CreateTransferTables().name]);
    // Parents first: users before the posts that reference them.
    final order = report.rows.keys.toList();
    expect(order.indexOf('xfer_users'), lessThan(order.indexOf('xfer_posts')));
    expect(report.rows, {
      'xfer_users': 3,
      'xfer_posts': 2,
      'xfer_categories': 3,
    });

    final users = await target.table('xfer_users').orderBy('id').get();
    expect([for (final u in users) u['id']], [1, 2, 7]);
    bool truthy(Object? v) => v == true || v == 1 || v == '1';
    expect([for (final u in users) truthy(u['active'])], [true, false, true]);
    Object? decoded(Object? v) => v is String ? jsonDecode(v) : v;
    expect(decoded(users[0]['meta']), {'role': 'admin'});
    expect(users[1]['meta'], isNull);
    expect(decoded(users[2]['meta']), [1, 2]);
    final created = users[0]['created_at'];
    expect(
      created is DateTime
          ? created.toUtc().toIso8601String()
          : '$created'.replaceFirst(' ', 'T'),
      startsWith('2026-10-26T08:00:00'),
    );
    final categories = await target
        .table('xfer_categories')
        .orderBy('id')
        .get();
    expect([for (final c in categories) c['parent_id']], [null, 5, 1]);

    // The next id continues after the copied ones.
    await target.table('xfer_users').insert({'name': 'New', 'active': true});
    final fresh = await target.table('xfer_users').where('name', 'New').first();
    expect(fresh!['id'], 8);

    // A filled target is refused unless asked to replace it.
    await expectLater(
      DatabaseTransfer(
        source: source,
        target: target,
        migrations: migrations,
      ).run(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('--truncate'),
        ),
      ),
    );
    final again = await DatabaseTransfer(
      source: source,
      target: target,
      migrations: migrations,
      truncate: true,
    ).run();
    expect(again.migrated, isEmpty);
    expect(await target.table('xfer_users').count(), 3);
  }

  test('sqlite to sqlite', () async {
    final target = manager(
      ConnectionConfig(
        driver: 'sqlite',
        database: p.join(dir.path, 'target.sqlite'),
      ),
    );
    addTearDown(target.closeAll);
    await transferInto(target);
  });

  final pgUrl = Platform.environment['DARAVEL_TEST_PG'];
  test(
    'sqlite to PostgreSQL (sequences continue, booleans converted)',
    () async {
      final target = manager(fromUrl(pgUrl!));
      addTearDown(() async {
        await reset(target);
        await target.closeAll();
      });
      await reset(target);
      await transferInto(target);
      // The keys deferred for the copy are back to how migrations made them.
      final keys = await (await target.executor()).select(
        'SELECT constraint_name, is_deferrable '
        'FROM information_schema.table_constraints '
        "WHERE constraint_type = 'FOREIGN KEY' "
        "AND table_name IN ('xfer_posts', 'xfer_categories')",
      );
      expect(keys, hasLength(2));
      expect({for (final k in keys) k['is_deferrable']}, {'NO'});
    },
    skip: pgUrl == null || pgUrl.isEmpty ? 'DARAVEL_TEST_PG not set' : false,
  );

  final myUrl = Platform.environment['DARAVEL_TEST_MYSQL'];
  test(
    'sqlite to MySQL/MariaDB',
    () async {
      final target = manager(fromUrl(myUrl!));
      addTearDown(() async {
        await reset(target);
        await target.closeAll();
      });
      await reset(target);
      await transferInto(target);
    },
    skip: myUrl == null || myUrl.isEmpty ? 'DARAVEL_TEST_MYSQL not set' : false,
  );

  test('a dry run counts the source and changes nothing', () async {
    final source = await seededSource(p.join(dir.path, 'source.sqlite'));
    addTearDown(source.closeAll);
    final target = manager(
      ConnectionConfig(
        driver: 'sqlite',
        database: p.join(dir.path, 'target.sqlite'),
      ),
    );
    addTearDown(target.closeAll);
    final report = await DatabaseTransfer(
      source: source,
      target: target,
      migrations: migrations,
    ).run(dryRun: true);
    expect(report.rows, {
      'xfer_categories': 3,
      'xfer_posts': 2,
      'xfer_users': 3,
    });
    expect(await SchemaBuilder(await target.executor()).getTables(), isEmpty);
  });

  test(
    'the command copies between the configured database and a URL',
    () async {
      final sourcePath = p.join(dir.path, 'app.sqlite');
      final seeded = await seededSource(sourcePath);
      await seeded.closeAll();
      final targetPath = p.join(dir.path, 'copy.sqlite');
      Application createApp() => Application.configure(basePath: dir.path)
          .withEnv({
            'APP_ENV': 'local',
            'DB_CONNECTION': 'sqlite',
            'DB_DATABASE': sourcePath,
          })
          .withMigrations(migrations)
          .create();
      final code = await DartisanRunner(createApp)
          .run(['db:transfer', '--from=sqlite', '--to=sqlite:$targetPath']);
      expect(code, 0);
      final copy = manager(
        ConnectionConfig(driver: 'sqlite', database: targetPath),
      );
      addTearDown(copy.closeAll);
      expect(await copy.table('xfer_posts').count(), 2);
    },
  );
}
