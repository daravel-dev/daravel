import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Person extends Model {
  static final ModelDefinition<Person> definition = ModelDefinition<Person>(
    table: 'people',
    factory: Person.new,
  );

  @override
  ModelDefinition<Person> get modelDefinition => Person.definition;

  static const cols = (
    id: ModelColumn<Person, int>('id'),
    name: ModelColumn<Person, String>('name'),
    createdAt: ModelColumn<Person, String?>('created_at'),
  );
}

/// Typed columns (W9.1): a `ModelColumn` is the column's name at run time,
/// so every builder method that takes it gives the SQL and the rows of the
/// string, and a value that is not a column name is refused by name.
void main() {
  late DatabaseManager db;

  setUp(() async {
    db = DatabaseManager(
      const DatabaseConfig(
        defaultConnection: 'sqlite',
        connections: {
          'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
          'pgsql': ConnectionConfig(driver: 'pgsql', database: 'x'),
          'mysql': ConnectionConfig(driver: 'mysql', database: 'x'),
        },
      ),
    );
    await db.statement(
      'CREATE TABLE people ("id" INTEGER PRIMARY KEY AUTOINCREMENT, '
      '"name" TEXT, "created_at" TEXT)',
    );
    await db.table('people').insert([
      {'name': 'Ana', 'created_at': '2026-01-01 10:00:00'},
      {'name': 'Budi', 'created_at': '2026-01-02 10:00:00'},
    ]);
  });

  tearDown(() => db.closeAll());

  test('the token is the column name at run time', () {
    final Object column = Person.cols.name;
    expect(column, 'name');
    expect(column, isA<String>());
    expect(Person.cols.name.name, 'name');
  });

  test('latest, oldest, orderBy and where give the SQL of the string', () {
    for (final connection in ['sqlite', 'pgsql', 'mysql']) {
      QueryBuilder q() => db.table('people', connection: connection);
      expect(
        q()
            .where(Person.cols.name, 'Ana')
            .latest(Person.cols.createdAt)
            .toSql(),
        q().where('name', 'Ana').latest('created_at').toSql(),
        reason: connection,
      );
      expect(
        q().oldest(Person.cols.id).orderByDesc(Person.cols.name).toSql(),
        q().oldest('id').orderByDesc('name').toSql(),
        reason: connection,
      );
    }
  });

  test('pluck and value take tokens and return what strings return', () async {
    expect(
      await db.table('people').oldest(Person.cols.id).pluck(Person.cols.name),
      await db.table('people').oldest('id').pluck('name'),
    );
    expect(await db.table('people').pluck(Person.cols.name, Person.cols.id), {
      1: 'Ana',
      2: 'Budi',
    });
    expect(
      await db
          .table('people')
          .latest(Person.cols.id)
          .value<String>(Person.cols.name),
      'Budi',
    );
  });

  test('ModelQuery latest, oldest and pluck take tokens', () async {
    {
      final names = await Person.definition
          .query(db: db)
          .oldest(Person.cols.id)
          .pluck(Person.cols.name);
      expect(names, ['Ana', 'Budi']);
      final first = await Person.definition
          .query(db: db)
          .latest(Person.cols.createdAt)
          .first();
      expect(first?.getAttr<String>('name'), 'Budi');
    }
  });

  test('where(column == value) is refused, pointing at the right form', () {
    // `==` on a typed column is a Dart comparison, always false here.
    final comparison = Person.cols.name == 'Ana';
    final refusal = isA<ArgumentError>().having(
      (e) => '${e.message}',
      'message',
      contains('where(User.cols.email, value)'),
    );
    expect(() => db.table('people').where(comparison), throwsA(refusal));
    expect(() => db.table('people').orWhere(comparison), throwsA(refusal));
    expect(
      () => Person.definition.query(db: db).where(comparison),
      throwsA(refusal),
    );
  });

  test('a value that is not a column name is refused by parameter', () {
    expect(
      () => db.table('people').pluck(42),
      throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'column')),
    );
    expect(
      () => db.table('people').pluck('name', 3.5),
      throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'key')),
    );
    expect(
      () => db.table('people').value<Object>(true),
      throwsA(isA<ArgumentError>()),
    );
  });
}
