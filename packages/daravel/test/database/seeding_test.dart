import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Account extends Model {
  static final ModelDefinition<Account> definition = ModelDefinition<Account>(
    table: 'accounts',
    factory: Account.new,
    guarded: [],
    timestamps: false,
  );

  @override
  ModelDefinition<Account> get modelDefinition => Account.definition;

  String get email => getAttr('email');
  String get role => getAttr('role');
}

final class AccountSeeder extends Seeder {
  AccountSeeder(this.db);
  final DatabaseManager db;
  static int runs = 0;

  @override
  Future<void> run() async {
    runs++;
    await ModelFactory<Account>(
      Account.definition,
      (Faker f) => {'email': f.email(), 'role': 'user'},
      db: db,
    ).count(2).createMany();
  }
}

final class RootSeeder extends Seeder {
  RootSeeder(this.children);
  final List<Seeder> children;

  @override
  Future<void> run() => call(children);
}

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
    await SchemaBuilder(await db.executor()).create('accounts', (t) {
      t.id();
      t.string('email');
      t.string('role');
      t.integer('score').nullable();
    });
    AccountSeeder.runs = 0;
  });

  tearDown(() => db.closeAll());

  test('faker is deterministic with a seed and produces unique emails', () {
    final a = Faker(seed: 7);
    final b = Faker(seed: 7);
    expect(a.name(), b.name());
    expect(a.integer(min: 1, max: 6), inInclusiveRange(1, 6));
    expect(a.email(), isNot(a.email()));
    expect(
      a.uuid(),
      matches(
        RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        ),
      ),
    );
    expect(a.sentence(), endsWith('.'));
    expect(a.text(50).length, lessThanOrEqualTo(50));
    expect(a.pickMany([1, 2, 3, 4], 2).length, 2);
    final past = a.pastDate(days: 10);
    expect(
      past.isBefore(DateTime.now().toUtc().add(const Duration(seconds: 1))),
      isTrue,
    );
  });

  test(
    'factory: definition, states, sequence, overrides, callbacks, make/create',
    () async {
      var made = 0;
      var created = 0;
      final factory = ModelFactory<Account>(
        Account.definition,
        (Faker f) => {
          'email': f.email(),
          'role': 'user',
          'score': f.integer(min: 1, max: 9),
        },
        states: {
          'admin': (_) => {'role': 'admin'},
        },
        faker: Faker(seed: 1),
        db: db,
      ).afterMaking((_) => made++).afterCreating((_) => created++);

      final unsaved = await factory.make({'email': 'fixed@x.test'});
      expect(unsaved.exists, isFalse);
      expect(unsaved.email, 'fixed@x.test');
      expect(made, 1);
      expect(created, 0);

      final admins = await factory.count(3).state('admin').sequence([
        {'score': 1},
        {'score': 2},
      ]).createMany();
      expect(admins.length, 3);
      expect(
        admins.every((Account a) => a.exists && a.role == 'admin'),
        isTrue,
      );
      expect(admins.map((a) => a.getAttr<int>('score')), [1, 2, 1]);
      expect(created, 3);
      expect(await Account.definition.query(db: db).count(), 3);

      final custom = await factory
          .state({'role': 'guest'})
          .state((Faker f) => {'score': 99})
          .create();
      expect(custom.role, 'guest');
      expect(custom.getAttr<int>('score'), 99);
      expect(() => factory.state('nope'), throwsArgumentError);
      expect(factory.raw()['role'], 'user');
    },
  );

  test('seeder registry runs the root seeder, a named seeder or all', () async {
    final child = AccountSeeder(db);
    final registry = SeederRegistry([
      RootSeeder([child]),
      child,
    ]);
    expect(await registry.run(), ['RootSeeder']);
    expect(AccountSeeder.runs, 1);
    expect(await Account.definition.query(db: db).count(), 2);

    expect(await registry.run(name: 'AccountSeeder'), ['AccountSeeder']);
    expect(AccountSeeder.runs, 2);
    expect(() => registry.run(name: 'Missing'), throwsArgumentError);

    expect(await registry.run(all: true), ['RootSeeder', 'AccountSeeder']);
    expect(AccountSeeder.runs, 4);
    expect(await SeederRegistry(const []).run(), isEmpty);
  });
}
