import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class _CreateT extends Migration {
  const _CreateT();

  @override
  String get name => 'create_t';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('t', (table) {
    table.id();
    table.string('name');
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('t');
}

final class _CreateU extends Migration {
  const _CreateU();

  @override
  String get name => 'create_u';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('u', (table) {
    table.id();
    table.integer('t_id');
    table.boolean('flag').defaultTo(false);
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('u');
}

DatabaseManager _manager() => DatabaseManager(
  const DatabaseConfig(
    defaultConnection: 'sqlite',
    connections: <String, ConnectionConfig>{
      'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
    },
  ),
);

void main() {
  late DatabaseManager db;

  setUp(() async {
    db = _manager();
    await db.statement(
      'CREATE TABLE t ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT, "active" TINYINT(1))',
    );
  });

  tearDown(() => db.closeAll());

  test(
    'select / execute / insertGetId use bindings (no interpolation)',
    () async {
      final id = await db.insertGetId(
        'INSERT INTO t ("name", "active") VALUES (?, ?)',
        <Object?>['Ana', true],
      );
      expect(id, 1);

      final injected = await db.select(
        'SELECT * FROM t WHERE "name" = ?',
        <Object?>["Ana' OR 1=1 --"],
      );
      expect(injected, isEmpty);

      final rows = await db.select('SELECT * FROM t');
      expect(rows.single['name'], 'Ana');
      expect(rows.single['active'], 1);

      expect(
        await db.statement('UPDATE t SET "name" = ? WHERE "id" = ?', <Object?>[
          'Bo',
          id,
        ]),
        1,
      );
      expect(
        await db.statement('DELETE FROM t WHERE "id" = ?', <Object?>[999]),
        0,
      );
    },
  );

  test(
    'transactions roll back on error and nested calls join the outer one',
    () async {
      await expectLater(
        db.transaction(() async {
          await db.statement('INSERT INTO t ("name") VALUES (?)', <Object?>[
            'outer',
          ]);
          expect(db.inTransaction, isTrue);
          await db.transaction(() async {
            await db.statement('INSERT INTO t ("name") VALUES (?)', <Object?>[
              'inner',
            ]);
          });
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect(db.inTransaction, isFalse);
      final count = await db.select('SELECT COUNT(*) AS c FROM t');
      expect(count.single['c'], 0);
    },
  );

  test(
    'committed transactions persist and concurrent ones are serialized',
    () async {
      await Future.wait(
        List<Future<void>>.generate(
          5,
          (i) => db.transaction(() async {
            await db.statement('INSERT INTO t ("name") VALUES (?)', <Object?>[
              'row$i',
            ]);
            await Future<void>.delayed(const Duration(milliseconds: 2));
            await db.statement(
              'UPDATE t SET "active" = 1 WHERE "name" = ?',
              <Object?>['row$i'],
            );
          }),
        ),
      );
      final rows = await db.select(
        'SELECT COUNT(*) AS c FROM t WHERE "active" = 1',
      );
      expect(rows.single['c'], 5);
    },
  );

  test('migrator runs in batches, reports, rolls back and resets', () async {
    await db.statement('DROP TABLE t');

    // First deployment ships only `create_t` (batch 1).
    final first = Migrator(db, const <Migration>[_CreateT()]);
    expect(await first.run(), <String>['create_t']);
    expect(await first.run(), isEmpty);

    // Second deployment adds `create_u` (batch 2).
    final migrator = Migrator(db, const <Migration>[_CreateT(), _CreateU()]);
    expect(await migrator.run(), <String>['create_u']);

    final status = await migrator.status();
    expect(status.map((s) => s.ran), <bool>[true, true]);
    expect(status.map((s) => s.batch), <int?>[1, 2]);

    final schema = SchemaBuilder(await db.executor());
    expect(await schema.hasTable('u'), isTrue);
    expect(await schema.hasTable('nope'), isFalse);

    // Rolling back one step only undoes the latest batch.
    expect(await migrator.rollback(), <String>['create_u']);
    expect(await schema.hasTable('u'), isFalse);
    expect(await schema.hasTable('t'), isTrue);

    expect(await migrator.rollback(), <String>['create_t']);
    expect(await schema.hasTable('t'), isFalse);
    expect((await migrator.status()).every((s) => !s.ran), isTrue);

    // After a full rollback numbering restarts at 1 (Laravel parity).
    expect(await migrator.run(), <String>['create_t', 'create_u']);
    expect((await migrator.status()).map((s) => s.batch), <int?>[1, 1]);
    expect(await migrator.reset(), <String>['create_u', 'create_t']);
    expect(await schema.hasTable('t'), isFalse);
  });

  test('rollback of an unregistered migration fails loudly', () async {
    final migrator = Migrator(db, const <Migration>[]);
    await migrator.install();
    await db.statement(
      'INSERT INTO "migrations" ("migration", "batch") VALUES (?, ?)',
      <Object?>['ghost', 1],
    );
    await expectLater(migrator.rollback(), throwsStateError);
  });

  test('sqlite grammar compiles the expected DDL', () {
    final blueprint = Blueprint('users')
      ..id()
      ..string('email').unique()
      ..integer('age').nullable().defaultTo(0)
      ..string('role', length: 20).defaultTo('user')
      ..timestamps()
      ..index(<String>['age'])
      ..unique(<String>['email', 'role'], name: 'email_role');

    final statements = const SqliteSchemaGrammar().compileCreate(blueprint);
    expect(
      statements.first,
      'CREATE TABLE "users" ('
      '"id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, '
      '"email" VARCHAR(255) NOT NULL UNIQUE, '
      '"age" INTEGER NULL DEFAULT 0, '
      '"role" VARCHAR(20) NOT NULL DEFAULT \'user\', '
      '"created_at" DATETIME NULL, '
      '"updated_at" DATETIME NULL)',
    );
    expect(statements[1], 'CREATE INDEX "users_age_index" ON "users" ("age")');
    expect(
      statements[2],
      'CREATE UNIQUE INDEX "email_role" ON "users" ("email", "role")',
    );
  });

  test('identifiers are validated, never interpolated blindly', () {
    const grammar = SqliteSchemaGrammar();
    expect(() => grammar.wrap('users; DROP TABLE x'), throwsArgumentError);
    expect(grammar.wrap('users_2'), '"users_2"');
    expect(grammar.literal("O'Reilly"), "'O''Reilly'");
  });

  test('unknown connections and drivers fail with clear errors', () async {
    expect(() => db.connection('nope'), throwsA(isA<ConfigException>()));
    final pg = DatabaseManager(
      const DatabaseConfig(
        defaultConnection: 'mysql',
        connections: <String, ConnectionConfig>{
          'mysql': ConnectionConfig(driver: 'mysql', database: 'x'),
        },
      ),
    );
    expect(() => pg.connection(), throwsUnsupportedError);
  });
}
