import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

enum Level { low, high }

extension type const ItemId(int value) {}

final class Item extends Model {
  static final ModelDefinition<Item> definition = ModelDefinition<Item>(
    table: 'items',
    factory: Item.new,
  );

  @override
  ModelDefinition<Item> get modelDefinition => Item.definition;

  static const cols = (
    id: ModelColumn<Item, ItemId>('id'),
    name: ModelColumn<Item, String>('name'),
    note: ModelColumn<Item, String?>('note'),
    qty: ModelColumn<Item, int>('qty'),
    price: ModelColumn<Item, double?>('price'),
    active: ModelColumn<Item, bool>('active'),
    level: ModelColumn<Item, Level>('level'),
    seenAt: ModelColumn<Item, DateTime?>('seen_at'),
  );
}

/// Typed column conditions (W9.2): each builds the node that
/// `where(column, operator, value)` builds, so the SQL and the bindings are
/// those of the string form on every grammar; `startsWith`, `endsWith` and
/// `contains` take their text literally.
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
      'CREATE TABLE items ("id" INTEGER PRIMARY KEY AUTOINCREMENT, '
      '"name" TEXT, "note" TEXT, "qty" INTEGER)',
    );
    await db.table('items').insert([
      {'name': '100% cotton', 'note': null, 'qty': 1},
      {'name': '1000 cotton', 'note': 'a', 'qty': 5},
      {'name': 'snake_case', 'note': 'b', 'qty': 9},
      {'name': 'snakeXcase', 'note': null, 'qty': 12},
      {'name': 'wow!', 'note': 'c', 'qty': 3},
    ]);
  });

  tearDown(() => db.closeAll());

  void same(
    QueryBuilder Function(QueryBuilder q) typed,
    QueryBuilder Function(QueryBuilder q) string,
    String reason,
  ) {
    for (final connection in ['sqlite', 'pgsql', 'mysql']) {
      QueryBuilder q() => db.table('items', connection: connection);
      final a = typed(q());
      final b = string(q());
      expect(a.toSql(), b.toSql(), reason: '$reason ($connection)');
      expect(a.getBindings(), b.getBindings(), reason: '$reason ($connection)');
    }
  }

  test('SQL and bindings equal the string form, for every value type', () {
    final at = DateTime.utc(2026, 11, 11, 8);
    same(
      (q) => q.where(Item.cols.name.eq('Ana')),
      (q) => q.where('name', 'Ana'),
      'String',
    );
    same(
      (q) => q.where(Item.cols.qty.gte(3)),
      (q) => q.where('qty', '>=', 3),
      'int',
    );
    same(
      (q) => q.where(Item.cols.price.lt(9.5)),
      (q) => q.where('price', '<', 9.5),
      'double',
    );
    same(
      (q) => q.where(Item.cols.active.eq(true)),
      (q) => q.where('active', true),
      'bool',
    );
    same(
      (q) => q.where(Item.cols.seenAt.gt(at)),
      (q) => q.where('seen_at', '>', at),
      'DateTime',
    );
    same(
      (q) => q.where(Item.cols.level.eq(Level.high)),
      (q) => q.where('level', Level.high),
      'enum',
    );
    same(
      (q) => q.where(Item.cols.id.eq(const ItemId(7))),
      (q) => q.where('id', const ItemId(7)),
      'typed id',
    );
    same(
      (q) => q.where(Item.cols.note.eq(null)),
      (q) => q.where('note', null),
      'null',
    );
    same(
      (q) => q.where(Item.cols.note.neq(null)),
      (q) => q.whereNotNull('note'),
      'not null',
    );
    same(
      (q) => q.where(Item.cols.qty.inValues([1, 2])),
      (q) => q.whereIn('qty', [1, 2]),
      'in',
    );
    same(
      (q) => q.where(Item.cols.qty.inValues(const [])),
      (q) => q.whereIn('qty', const []),
      'in []',
    );
    same(
      (q) => q.where(Item.cols.qty.notInValues([1])),
      (q) => q.whereNotIn('qty', [1]),
      'not in',
    );
    same(
      (q) => q.where(Item.cols.qty.between(1, 5)),
      (q) => q.whereBetween('qty', 1, 5),
      'between',
    );
    same(
      (q) => q.where(Item.cols.note.isNull()),
      (q) => q.whereNull('note'),
      'is null',
    );
    same(
      (q) => q.where(Item.cols.note.isNotNull()),
      (q) => q.whereNotNull('note'),
      'is not null',
    );
    same(
      (q) => q.where(Item.cols.name.like('a%')),
      (q) => q.where('name', 'like', 'a%'),
      'like',
    );
    same(
      (q) => q.where('qty', 1).orWhere(Item.cols.qty.gt(9)),
      (q) => q.where('qty', 1).orWhere('qty', '>', 9),
      'orWhere',
    );
  });

  test('startsWith, endsWith and contains take the text literally', () async {
    Future<List<Object?>> names(ColumnPredicate<Item> p) async =>
        await db.table('items').where(p).orderBy('id').pluck('name') as List;
    expect(await names(Item.cols.name.startsWith('100%')), ['100% cotton']);
    expect(await names(Item.cols.name.contains('_')), ['snake_case']);
    expect(await names(Item.cols.name.endsWith('!')), ['wow!']);
    expect(await names(Item.cols.name.contains('cotton')), [
      '100% cotton',
      '1000 cotton',
    ]);
    expect(
      db.table('items').where(Item.cols.name.startsWith('5%_')).toSql(),
      contains("LIKE ? ESCAPE '!'"),
    );
    expect(
      db.table('items').where(Item.cols.name.startsWith('5%_!')).getBindings(),
      ['5!%!_!!%'],
    );
  });

  test('conditions run on SQLite, joined with AND and OR', () async {
    final rows = await db
        .table('items')
        .where(Item.cols.qty.gte(5))
        .where(Item.cols.note.isNotNull())
        .orWhere(Item.cols.qty.eq(1))
        .orderBy('id')
        .pluck('qty');
    expect(rows, [1, 5, 9]);
    expect(
      await db.table('items').where(Item.cols.qty.inValues(const [])).count(),
      0,
    );
  });

  test('ModelQuery and the model statics take conditions', () async {
    final names = await Item.definition
        .query(db: db)
        .where(Item.cols.qty.between(4, 10))
        .orderByDesc(Item.cols.qty)
        .pluck(Item.cols.name);
    expect(names, ['snake_case', '1000 cotton']);
  });
}
