import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `where` counts its arguments as Laravel 13 does (`Query/Builder.php`:
/// `where`, `prepareValueAndOperator`, `invalidOperatorAndValue`,
/// `invalidOperator`), with a default marker for PHP's `func_num_args()`.
void main() {
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
    await db.statement(
      'CREATE TABLE posts ("id" INTEGER PRIMARY KEY AUTOINCREMENT, '
      '"title" TEXT, "deleted_at" TEXT, "created_at" TEXT)',
    );
    await db.table('posts').insert([
      {'title': '<>', 'deleted_at': null, 'created_at': '2026-01-01 10:00:00'},
      {'title': 'b', 'deleted_at': '2026-01-02 00:00:00', 'created_at': null},
    ]);
  });

  tearDown(() => db.closeAll());

  QueryBuilder q() => db.table('posts');

  test('three arguments with null: = is IS NULL, != and <> IS NOT NULL', () {
    expect(
      q().where('deleted_at', '=', null).toSql(),
      contains('"deleted_at" IS NULL'),
    );
    expect(
      q().where('deleted_at', '!=', null).toSql(),
      contains('"deleted_at" IS NOT NULL'),
    );
    expect(
      q().where('deleted_at', '<>', null).toSql(),
      contains('"deleted_at" IS NOT NULL'),
    );
    expect(
      q().orWhere('deleted_at', '<>', null).toSql(),
      contains('IS NOT NULL'),
    );
  });

  test('three arguments with null and another operator are refused', () {
    for (final op in ['>', '<=', 'like']) {
      expect(
        () => q().where('deleted_at', op, null),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('Illegal operator and value combination'),
          ),
        ),
        reason: op,
      );
    }
  });

  test('two arguments: the second is the value, operator or not', () async {
    expect(q().where('deleted_at', null).toSql(), contains('IS NULL'));
    expect(await q().where('title', '<>').pluck('title'), ['<>']);
    expect(q().where('title', '<>').getBindings(), ['<>']);
    expect(q().where('title', 'b').getBindings(), ['b']);
  });

  test('the rows: three-argument null filters as Laravel', () async {
    expect(await q().where('deleted_at', '!=', null).pluck('title'), ['b']);
    expect(await q().where('deleted_at', '=', null).pluck('title'), ['<>']);
  });

  test('a map is key = value for each entry', () {
    expect(
      q().where(const {'title': '<>', 'deleted_at': null}).toSql(),
      allOf(contains('"title" = ?'), contains('"deleted_at" IS NULL')),
    );
  });

  test(
    'a null value with a non-operator second argument is = (invalidOperator)',
    () {
      // What a model's generated `where` static passes on for where('title', 'b').
      expect(q().where('title', 'b', null).getBindings(), ['b']);
      expect(q().where('deleted_at', null, null).toSql(), contains('IS NULL'));
    },
  );

  test('ModelQuery forwards the count', () {
    final definition = ModelDefinition<_Post>(
      table: 'posts',
      factory: _Post.new,
    );
    expect(
      definition.query(db: db).where('deleted_at', '<>', null).builder.toSql(),
      contains('IS NOT NULL'),
    );
    expect(
      definition.query(db: db).where('title', '<>').builder.getBindings(),
      ['<>'],
    );
    expect(
      definition
          .query(db: db)
          .orWhere('deleted_at', '!=', null)
          .builder
          .toSql(),
      contains('IS NOT NULL'),
    );
  });

  test('whereDate and friends count too', () {
    expect(q().whereDate('created_at', '2026-01-01').getBindings(), [
      '2026-01-01',
    ]);
    expect(
      () => q().whereDate('created_at', '>', null),
      throwsA(isA<ArgumentError>()),
    );
  });
}

final class _Post extends Model {
  @override
  ModelDefinition<_Post> get modelDefinition =>
      ModelDefinition<_Post>(table: 'posts', factory: _Post.new);
}
