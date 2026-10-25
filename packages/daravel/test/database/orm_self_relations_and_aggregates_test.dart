import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/test_databases.dart';

/// A tree: categories whose parent and children are categories.
final class Category extends Model {
  static final ModelDefinition<Category> definition = ModelDefinition<Category>(
    table: 'categories',
    factory: Category.new,
    guarded: [],
    timestamps: false,
    softDeletes: true,
    relations: {
      'parent': () => BelongsTo<Category>(
        () => Category.definition,
        foreignKey: 'parent_id',
      ),
      'children': () =>
          HasMany<Category>(() => Category.definition, foreignKey: 'parent_id'),
    },
  );
  @override
  ModelDefinition<Category> get modelDefinition => Category.definition;
  String get name => getAttr('name');
}

/// Users following users through `follows`.
final class Member extends Model {
  static final ModelDefinition<Member> definition = ModelDefinition<Member>(
    table: 'members',
    factory: Member.new,
    guarded: [],
    timestamps: false,
    relations: {
      'following': () => BelongsToMany<Member>(
        () => Member.definition,
        pivotTable: 'follows',
        foreignPivotKey: 'follower_id',
        relatedPivotKey: 'followed_id',
      ),
      'orders': () =>
          HasMany<Order>(() => Order.definition, foreignKey: 'member_id'),
    },
  );
  @override
  ModelDefinition<Member> get modelDefinition => Member.definition;
  String get name => getAttr('name');
}

final class Order extends Model {
  static final ModelDefinition<Order> definition = ModelDefinition<Order>(
    table: 'orders',
    factory: Order.new,
    guarded: [],
    timestamps: false,
  );
  @override
  ModelDefinition<Order> get modelDefinition => Order.definition;
}

/// Laravel's hasOneThrough example: mechanic → car → owner.
final class Mechanic extends Model {
  static final ModelDefinition<Mechanic> definition = ModelDefinition<Mechanic>(
    table: 'mechanics',
    factory: Mechanic.new,
    guarded: [],
    timestamps: false,
    relations: {
      'carOwner': () => HasOneThrough<Owner>(
        () => Owner.definition,
        through: () => Car.definition,
        firstKey: 'mechanic_id',
        secondKey: 'car_id',
      ),
    },
  );
  @override
  ModelDefinition<Mechanic> get modelDefinition => Mechanic.definition;
  String get name => getAttr('name');
}

final class Car extends Model {
  static final ModelDefinition<Car> definition = ModelDefinition<Car>(
    table: 'cars',
    factory: Car.new,
    guarded: [],
    timestamps: false,
  );
  @override
  ModelDefinition<Car> get modelDefinition => Car.definition;
}

final class Owner extends Model {
  static final ModelDefinition<Owner> definition = ModelDefinition<Owner>(
    table: 'owners',
    factory: Owner.new,
    guarded: [],
    timestamps: false,
  );
  @override
  ModelDefinition<Owner> get modelDefinition => Owner.definition;
  String get name => getAttr('name');
}

const List<String> _tables = [
  'categories',
  'members',
  'follows',
  'orders',
  'mechanics',
  'cars',
  'owners',
];

Future<DatabaseManager> _database(DatabaseOpener open) async {
  final db = open();
  final schema = await freshSchema(db, _tables);
  await schema.create('categories', (t) {
    t.id();
    t.integer('parent_id').nullable();
    t.string('name');
    t.timestamp('deleted_at').nullable();
  });
  await schema.create('members', (t) {
    t.id();
    t.string('name');
  });
  await schema.create('follows', (t) {
    t.integer('follower_id');
    t.integer('followed_id');
  });
  await schema.create('orders', (t) {
    t.id();
    t.integer('member_id');
    t.integer('total');
  });
  await schema.create('mechanics', (t) {
    t.id();
    t.string('name');
  });
  await schema.create('cars', (t) {
    t.id();
    t.integer('mechanic_id');
  });
  await schema.create('owners', (t) {
    t.id();
    t.integer('car_id');
    t.string('name');
  });
  return db;
}

void main() => forEachDatabase(selfRelationAndAggregateTests);

/// Also run on MySQL and MariaDB by daravel_mysql/test/orm_matrix_test.dart.
void selfRelationAndAggregateTests(DatabaseOpener open) {
  late DatabaseManager db;

  setUp(() async => db = await _database(open));
  tearDown(() => db.closeAll());

  group('self relations', () {
    ModelQuery<Category> categories() =>
        Category.definition.query(db: db).orderBy('id');
    List<String> names(List<Category> list) => [for (final c in list) c.name];

    setUp(() async {
      // languages > dart > flutter; languages > php (deleted); tools
      Future<int> add(String name, [int? parent]) async =>
          (await Category.definition.query(db: db).create({
                'name': name,
                'parent_id': parent,
              })).key!
              as int;
      final languages = await add('languages');
      final dart = await add('dart', languages);
      await add('flutter', dart);
      final php = await add('php', languages);
      await add('tools');
      await db.table('categories').where('id', php).update({
        'deleted_at': '2026-01-01 00:00:00',
      });
    });

    test('whereHas aliases the inner table like Laravel', () async {
      final query = categories().whereHas(
        'children',
        (q) => q.where('name', 'dart'),
      );
      expect(
        query.toSql(),
        matches(RegExp(r'["`]categories["`] AS ["`]laravel_reserved_\d+["`]')),
      );
      expect(names(await query.get()), ['languages']);
      expect(names(await categories().has('parent').get()), [
        'dart',
        'flutter',
      ]);
      expect(names(await categories().doesntHave('children').get()), [
        'flutter',
        'tools',
      ]);
    });

    test('soft deletes and nesting use the alias of each level', () async {
      // php is deleted: it neither counts as a child nor matches.
      expect(
        names(
          await categories()
              .whereHas('children', (q) => q.where('name', 'php'))
              .get(),
        ),
        isEmpty,
      );
      // Grandchildren: two aliased levels.
      expect(names(await categories().has('children.children').get()), [
        'languages',
      ]);
      final counted = await categories().withCount('children').get();
      expect(
        [for (final c in counted) c.getAttr<int>('children_count')],
        [1, 1, 0, 0],
      );
    });

    test('a self-referencing pivot correlates with the outer table', () async {
      final ana = await Member.definition.query(db: db).create({'name': 'Ana'});
      final bo = await Member.definition.query(db: db).create({'name': 'Bo'});
      await Member.definition.query(db: db).create({'name': 'Cy'});
      await ana.attach('following', [bo]);
      final followers = await Member.definition
          .query(db: db)
          .whereHas('following', (q) => q.where('name', 'Bo'))
          .pluck('name');
      expect(followers, ['Ana']);
      final withCount = await Member.definition
          .query(db: db)
          .withCount('following')
          .orderBy('id')
          .get();
      expect(
        [for (final m in withCount) m.getAttr<int>('following_count')],
        [1, 0, 0],
      );
    });
  });

  test('hasOneThrough loads one model or null', () async {
    final m1 = await Mechanic.definition.query(db: db).create({'name': 'M1'});
    await Mechanic.definition.query(db: db).create({'name': 'M2'});
    final car = await Car.definition.query(db: db).create({
      'mechanic_id': m1.key,
    });
    await Owner.definition.query(db: db).create({
      'car_id': car.key,
      'name': 'Olga',
    });
    final mechanics = await Mechanic.definition
        .query(db: db)
        .with_('carOwner')
        .orderBy('id')
        .get();
    expect(mechanics[0].related<Owner?>('carOwner')!.name, 'Olga');
    expect(mechanics[1].related<Owner?>('carOwner'), isNull);
    expect(
      await Mechanic.definition.query(db: db).has('carOwner').pluck('name'),
      ['M1'],
    );
  });

  test('withSum, withAvg, withMin, withMax and withExists', () async {
    final ana = await Member.definition.query(db: db).create({'name': 'Ana'});
    await Member.definition.query(db: db).create({'name': 'Bo'});
    for (final total in [10, 30, 50]) {
      await db.table('orders').insert({'member_id': ana.key, 'total': total});
    }
    final members = await Member.definition
        .query(db: db)
        .withSum('orders', 'total')
        .withAvg('orders', 'total')
        .withMin('orders', 'total')
        .withMax({
          'orders': (ModelQuery<Model> q) => q.where('total', '<', 50),
        }, 'total')
        .withExists('orders')
        .withCount('orders as big_orders')
        .orderBy('id')
        .get();
    final a = members[0];
    // SUM and AVG are DECIMAL on MySQL and numeric on PostgreSQL, read as
    // strings there (as with Laravel's PDO).
    num value(String column) => num.parse('${a.getAttr<Object?>(column)}');
    expect(value('orders_sum_total'), 90);
    expect(value('orders_avg_total'), 30);
    expect(value('orders_min_total'), 10);
    expect(value('orders_max_total'), 30);
    expect(a.getAttr<Object?>('orders_exists'), isTrue);
    expect(a.getAttr<Object?>('big_orders'), 3);
    final b = members[1];
    expect(b.getAttr<Object?>('orders_sum_total'), isNull);
    expect(b.getAttr<Object?>('orders_exists'), isFalse);
  });
}
