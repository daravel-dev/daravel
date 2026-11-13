import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/test_databases.dart';

/// DB-1 (Reviewer RSEQ 49 #3): `select`, `statement` and `insertGetId` run
/// one statement on every driver and refuse a second, reported as a
/// `QueryException`; `unprepared` runs a script. MySQL ran a second
/// statement sent without bindings, and SQLite ran one sent through
/// `execute`/`insertGetId` without bindings.
void statementStackingTests(DatabaseOpener open) {
  late DatabaseManager db;
  const table = 'db1_stack';

  setUp(() async {
    db = open();
    final schema = await freshSchema(db, [table]);
    await schema.create(table, (t) => t.integer('n'));
  });
  tearDown(() => db.closeAll());

  Future<List<Object?>> values() async => [
    for (final row in await db.select('SELECT n FROM $table ORDER BY n'))
      int.parse('${row['n']}'),
  ];

  Matcher refused() => throwsA(
    isA<QueryException>().having(
      (e) => e.previous,
      'previous',
      db.dialectOf() == SqlDialect.sqlite
          ? isA<MultipleStatementsException>()
          : anything,
    ),
  );

  test('statement, select and insertGetId refuse a second statement, with '
      'or without bindings, and run nothing', () async {
    final second = 'INSERT INTO $table (n) VALUES (9)';
    await expectLater(
      db.statement('INSERT INTO $table (n) VALUES (1); $second'),
      refused(),
    );
    await expectLater(
      db.statement('INSERT INTO $table (n) VALUES (?); $second', [2]),
      refused(),
    );
    await expectLater(db.select('SELECT 1 AS a; $second'), refused());
    await expectLater(
      db.insertGetId('INSERT INTO $table (n) VALUES (3); $second'),
      refused(),
    );
    expect(await values(), isEmpty);
  });

  test('a trailing semicolon or comment is still one statement', () async {
    await db.statement('INSERT INTO $table (n) VALUES (1);');
    await db.statement('INSERT INTO $table (n) VALUES (2); -- why');
    expect(await values(), [1, 2]);
  });

  test('unprepared runs a script, also inside a transaction', () async {
    await db.unprepared(
      'INSERT INTO $table (n) VALUES (1); INSERT INTO $table (n) VALUES (2)',
    );
    await db.transaction(() async {
      await db.unprepared(
        'INSERT INTO $table (n) VALUES (3); INSERT INTO $table (n) VALUES (4)',
      );
    });
    expect(await values(), [1, 2, 3, 4]);
  });

  test('a failing unprepared script is a QueryException', () async {
    await expectLater(
      db.unprepared('INSERT INTO no_such_table_db1 (n) VALUES (1)'),
      throwsA(isA<QueryException>()),
    );
  });
}

void main() {
  forEachDatabase(statementStackingTests);

  test('DB.unprepared returns true, as Laravel\'s DB::unprepared', () async {
    final app = Application.configure(basePath: '.')
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    await app.run(() async {
      expect(
        await DB.unprepared('CREATE TABLE u (n int); INSERT INTO u VALUES (1)'),
        isTrue,
      );
      expect(await DB.select('SELECT n FROM u'), [
        {'n': 1},
      ]);
    });
  });
}
