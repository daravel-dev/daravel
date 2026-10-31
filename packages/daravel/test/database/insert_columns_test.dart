import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A row that names other columns than the first one must not lose them.
/// Laravel's statement fails with a column count error; here the mistake is
/// named before any SQL runs.
void main() {
  late DatabaseManager db;

  setUp(() async {
    db = DatabaseManager(
      DatabaseConfig(
        defaultConnection: 'sqlite',
        connections: {
          'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
        },
      ),
    );
    await db.statement(
      'CREATE TABLE t (id INTEGER PRIMARY KEY, a TEXT, b TEXT)',
    );
  });

  tearDown(() => db.closeAll());

  Future<List<Map<String, Object?>>> rows() =>
      db.select('SELECT a, b FROM t ORDER BY id');

  test('a row with an extra column is refused, nothing is written', () async {
    await expectLater(
      db.table('t').insert([
        {'a': '1'},
        {'a': '2', 'b': 'kept?'},
      ]),
      throwsArgumentError,
    );
    expect(await rows(), isEmpty);
  });

  test('a row with a missing column is refused', () {
    expect(
      db.table('t').insert([
        {'a': '1', 'b': 'x'},
        {'a': '2'},
      ]),
      throwsArgumentError,
    );
  });

  test('the same columns in another order are fine', () async {
    await db.table('t').insert([
      {'a': '1', 'b': 'x'},
      {'b': 'y', 'a': '2'},
    ]);
    expect(await rows(), [
      {'a': '1', 'b': 'x'},
      {'a': '2', 'b': 'y'},
    ]);
  });

  test('the error names the row and the columns', () {
    expect(
      () => QueryGrammar.forDialect(SqlDialect.sqlite).compileInsert('t', [
        {'a': 1},
        {'a': 2, 'b': 3},
      ]),
      throwsA(
        isA<ArgumentError>().having(
          (e) => '${e.message}',
          'message',
          allOf(contains('row 1'), contains('b')),
        ),
      ),
    );
  });
}
