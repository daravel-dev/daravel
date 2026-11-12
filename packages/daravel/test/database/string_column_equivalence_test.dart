import 'package:daravel/daravel.dart';
import 'package:daravel_lints/daravel_lints.dart';
import 'package:test/test.dart';

final class Item extends Model {
  static final ModelDefinition<Item> definition = ModelDefinition<Item>(
    table: 'items',
    factory: Item.new,
  );

  @override
  ModelDefinition<Item> get modelDefinition => Item.definition;

  static const cols = (
    id: ModelColumn<Item, int>('id'),
    name: ModelColumn<Item, String>('name'),
    qty: ModelColumn<Item, int>('qty'),
    createdAt: ModelColumn<Item, DateTime?>('created_at'),
  );
}

typedef _Run = Future<Object?> Function(ModelQuery<Item> q);

/// What the editor's fix for `string_column_name` changes (W9.8): in each
/// method the rule reports, a column written as its `cols` token runs the
/// same SQL with the same bindings as the string it replaces.
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
      'CREATE TABLE items ("id" INTEGER PRIMARY KEY AUTOINCREMENT, '
      '"name" TEXT, "qty" INTEGER, "created_at" TEXT, "updated_at" TEXT)',
    );
    await db.table('items').insert([
      {'name': 'a', 'qty': 1},
      {'name': 'b', 'qty': 5},
    ]);
  });

  tearDown(() => db.closeAll());

  const c = Item.cols;

  /// Per method: the call with the token, then with the string.
  final cases = <String, (_Run, _Run)>{
    'where': (
      (q) => q.where(c.qty, '>', 2).get(),
      (q) => q.where('qty', '>', 2).get(),
    ),
    'orWhere': (
      (q) => q.where(c.qty, 1).orWhere(c.name, 'b').get(),
      (q) => q.where('qty', 1).orWhere('name', 'b').get(),
    ),
    'orderBy': (
      (q) => q.orderBy(c.name, 'desc').get(),
      (q) => q.orderBy('name', 'desc').get(),
    ),
    'orderByDesc': (
      (q) => q.orderByDesc(c.qty).get(),
      (q) => q.orderByDesc('qty').get(),
    ),
    'latest': ((q) => q.latest(c.qty).get(), (q) => q.latest('qty').get()),
    'oldest': ((q) => q.oldest(c.qty).get(), (q) => q.oldest('qty').get()),
    'pluck': ((q) => q.pluck(c.name, c.id), (q) => q.pluck('name', 'id')),
    'increment': (
      (q) => q.where(c.id, 1).increment(c.qty, 2),
      (q) => q.where('id', 1).increment('qty', 2),
    ),
    'decrement': (
      (q) => q.where(c.id, 1).decrement(c.qty),
      (q) => q.where('id', 1).decrement('qty'),
    ),
    'min': ((q) => q.min(c.qty), (q) => q.min('qty')),
    'max': ((q) => q.max(c.qty), (q) => q.max('qty')),
    'sum': ((q) => q.sum(c.qty), (q) => q.sum('qty')),
    'avg': ((q) => q.avg(c.qty), (q) => q.avg('qty')),
    'count': ((q) => q.count(c.qty), (q) => q.count('qty')),
    'select': (
      (q) => q.select([c.id, c.name]).get(),
      (q) => q.select(['id', 'name']).get(),
    ),
    'groupBy': (
      (q) => q.select([c.qty]).groupBy([c.qty]).get(),
      (q) => q.select(['qty']).groupBy(['qty']).get(),
    ),
  };

  test('every method the rule reports has a case', () {
    expect(cases.keys.toSet(), {
      ...StringColumnName.firstArgument,
      ...StringColumnName.listArgument,
    });
  });

  for (final MapEntry(key: method, value: (typed, string)) in cases.entries) {
    test(
      '$method: the token runs the SQL and bindings of the string',
      () async {
        final (typedResult, typedQueries) = await db.captureQueries(
          () => typed(Item.definition.query(db: db)),
        );
        final (stringResult, stringQueries) = await db.captureQueries(
          () => string(Item.definition.query(db: db)),
        );
        expect(typedQueries, isNotEmpty);
        // A record holding a List compares it by identity: compare text.
        expect(
          [for (final q in typedQueries) '${q.sql} ${q.bindings}'],
          [for (final q in stringQueries) '${q.sql} ${q.bindings}'],
        );
        // increment/decrement change the row between the two runs; the rest
        // read the same rows.
        if (method != 'increment' && method != 'decrement') {
          expect('$typedResult', '$stringResult');
        }
      },
    );
  }
}
