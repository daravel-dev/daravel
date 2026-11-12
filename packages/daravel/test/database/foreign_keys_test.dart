import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `Schema.getForeignKeys` (#330), in the shape of Laravel 13's
/// `Schema::getForeignKeys`. The golden
/// (`fixtures/laravel_foreign_keys_sqlite.json`) holds the DDL and what
/// Laravel 13.40 returned for it on SQLite; PostgreSQL and MySQL run the
/// grammar's query in their integration suites.
void main() {
  final golden = jsonDecode(
    File('test/database/fixtures/laravel_foreign_keys_sqlite.json')
        .readAsStringSync(),
  ) as Map<String, Object?>;

  Map<String, Object?> asLaravel(ForeignKeyInfo key) => {
    'name': key.name,
    'columns': key.columns,
    'foreign_schema': key.foreignSchema,
    'foreign_table': key.foreignTable,
    'foreign_columns': key.foreignColumns,
    'on_update': key.onUpdate,
    'on_delete': key.onDelete,
  };

  late DatabaseManager db;

  setUp(() async {
    db = DatabaseManager(
      const DatabaseConfig(
        defaultConnection: 'sqlite',
        connections: {
          'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
        },
      ),
    );
    for (final sql in (golden['statements']! as List<Object?>).cast<String>()) {
      await db.statement(sql);
    }
  });
  tearDown(() => db.closeAll());

  Future<SchemaBuilder> schema() async => SchemaBuilder(await db.connection());

  test('SQLite: what Laravel 13 returns, table by table', () async {
    final builder = await schema();
    final expected = golden['foreign_keys']! as Map<String, Object?>;
    for (final MapEntry(key: table, value: keys) in expected.entries) {
      final found = [
        for (final key in await builder.getForeignKeys(table)) asLaravel(key),
      ];
      // One difference, on purpose: a key that leaves its referenced
      // columns out (`REFERENCES assessments`) is ['' ] in Laravel
      // (`explode` of null) and empty here.
      final laravel = [
        for (final key in (keys! as List<Object?>).cast<Map<String, Object?>>())
          {
            ...key,
            if (key['foreign_columns'] case [''])
              'foreign_columns': const <String>[],
          },
      ];
      expect(found, laravel, reason: table);
    }
  });

  test('the actions and a composite key', () async {
    final keys = await (await schema()).getForeignKeys('sessions');
    final byColumn = {for (final key in keys) key.columns.single: key};
    expect(byColumn['assessment_id']!.onDelete, 'cascade');
    expect(byColumn['user_id']!.onUpdate, 'cascade');
    expect(byColumn['user_id']!.onDelete, 'set null');
    expect(byColumn['parent_id']!.foreignTable, 'sessions');
    final composite = (await (await schema()).getForeignKeys('grades')).single;
    expect(composite.columns, ['session_id', 'assessment_id']);
    expect(composite.foreignColumns, ['a', 'b']);
  });

  test('a table name is bound, never written into the SQL', () {
    for (final grammar in [
      const SqliteSchemaGrammar(),
      const PostgresSchemaGrammar(),
      const MySqlSchemaGrammar(),
    ]) {
      final sql = grammar.compileForeignKeys();
      expect(sql, isNot(contains("x'; drop")), reason: '${grammar.dialect}');
      expect(
        grammar.foreignKeyBindings("x'; drop table users; --"),
        contains("x'; drop table users; --"),
        reason: '${grammar.dialect}',
      );
    }
    // MySQL never sees a double-quoted identifier.
    expect(
      const MySqlSchemaGrammar().compileForeignKeys(),
      isNot(contains('"')),
    );
  });

  test('a key without referenced columns has none', () async {
    final key = (await (await schema()).getForeignKeys('kids')).single;
    expect(key.columns, ['assessment_id']);
    expect(key.foreignTable, 'assessments');
    expect(key.foreignColumns, isEmpty);
    expect(key.onDelete, 'cascade');
  });

  test('a grammar written elsewhere still compiles and says it has no '
      'foreign keys', () {
    expect(
      () => const _ThirdPartyGrammar().compileForeignKeys(),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('does not report foreign keys'),
        ),
      ),
    );
  });

  test('PostgreSQL names its one-letter actions as Laravel does', () {
    const grammar = PostgresSchemaGrammar();
    expect(
      [
        for (final code in ['a', 'r', 'c', 'n', 'd', 'x'])
          grammar.foreignKeyAction(code),
      ],
      ['no action', 'restrict', 'cascade', 'set null', 'set default', null],
    );
  });
}

/// A grammar as one written outside Daravel before `compileForeignKeys`:
/// it implements only what was abstract then, and still compiles.
final class _ThirdPartyGrammar extends SchemaGrammar {
  const _ThirdPartyGrammar();

  @override
  SqlDialect get dialect => SqlDialect.sqlite;

  @override
  String typeFor(ColumnDefinition column) => 'text';

  @override
  String get autoIncrementClause => '';

  @override
  String compileTableExists() => 'select 1';

  @override
  String compileViewExists() => 'select 1';

  @override
  String compileListTables() => 'select 1';

  @override
  String compileColumns() => 'select 1';

  @override
  ColumnInfo columnInfo(Map<String, Object?> row) =>
      const ColumnInfo(name: 'x', type: 'text', nullable: true);

  @override
  List<String> compileChange(String table, ColumnDefinition column) => const [];
}
