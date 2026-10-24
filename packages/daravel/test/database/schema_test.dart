import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

DatabaseManager _manager() => DatabaseManager(
  const DatabaseConfig(
    defaultConnection: 'sqlite',
    connections: {
      'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
    },
  ),
);

void main() {
  late DatabaseManager db;
  late SchemaBuilder schema;

  setUp(() async {
    db = _manager();
    schema = SchemaBuilder(await db.executor());
  });

  tearDown(() => db.closeAll());

  group('grammar snapshots', () {
    Blueprint users() => Blueprint('users')
      ..id()
      ..string('email').unique()
      ..string('role').defaultTo('user')
      ..decimal('balance', precision: 10, scale: 2).defaultTo(0)
      ..enumeration('status', ['active', 'banned'])
      ..json('meta').nullable()
      ..uuid('external_id').nullable()
      ..timestamp('seen_at').useCurrent()
      ..softDeletes()
      ..timestamps();

    test('create with foreign keys per dialect', () {
      final posts = Blueprint('posts')
        ..id()
        ..foreignId('user_id').constrained().cascadeOnDelete()
        ..string('title').index();

      expect(const SqliteSchemaGrammar().compileCreate(posts), [
        'CREATE TABLE "posts" ("id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, "user_id" INTEGER NOT NULL, "title" VARCHAR(255) NOT NULL, '
            'CONSTRAINT "posts_user_id_foreign" FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE)',
        'CREATE INDEX "posts_title_index" ON "posts" ("title")',
      ]);
      expect(
        const PostgresSchemaGrammar().compileCreate(posts).first,
        'CREATE TABLE "posts" ("id" BIGSERIAL PRIMARY KEY, "user_id" BIGINT NOT NULL, "title" VARCHAR(255) NOT NULL, '
        'CONSTRAINT "posts_user_id_foreign" FOREIGN KEY ("user_id") REFERENCES "users" ("id") ON DELETE CASCADE)',
      );
      expect(
        const MySqlSchemaGrammar().compileCreate(posts).first,
        'CREATE TABLE `posts` (`id` BIGINT UNSIGNED NOT NULL AUTO_INCREMENT PRIMARY KEY, `user_id` BIGINT UNSIGNED NOT NULL, `title` VARCHAR(255) NOT NULL, '
        'CONSTRAINT `posts_user_id_foreign` FOREIGN KEY (`user_id`) REFERENCES `users` (`id`) ON DELETE CASCADE) '
        'DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci',
      );
    });

    test('column types and modifiers per dialect', () {
      final sqlite = const SqliteSchemaGrammar().compileCreate(users()).first;
      expect(sqlite, contains('"balance" NUMERIC(10, 2) NOT NULL DEFAULT 0'));
      expect(
        sqlite,
        contains(
          '"status" VARCHAR(255) NOT NULL CHECK ("status" IN (\'active\', \'banned\'))',
        ),
      );
      expect(
        sqlite,
        contains('"seen_at" DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP'),
      );
      expect(sqlite, contains('"deleted_at" DATETIME NULL'));

      final pg = const PostgresSchemaGrammar().compileCreate(users()).first;
      expect(pg, contains('"meta" JSONB NULL'));
      expect(pg, contains('"external_id" UUID NULL'));

      final my = const MySqlSchemaGrammar().compileCreate(users()).first;
      expect(my, contains("`status` ENUM('active', 'banned') NOT NULL"));
      expect(my, contains('`meta` JSON NULL'));
    });

    test('alter statements for postgres and mysql', () {
      final bp = Blueprint('users', alter: true)
        ..string('nickname').nullable()
        ..integer('age').nullable().change()
        ..dropColumn('legacy')
        ..renameColumn('name', 'full_name')
        ..dropIndex('users_email_unique')
        ..dropForeign(['team_id'])
        ..foreign(['team_id']).references('id').on('teams').nullOnDelete()
        ..index(['age']);
      expect(const PostgresSchemaGrammar().compileAlter(bp), [
        'ALTER TABLE "users" DROP CONSTRAINT "users_team_id_foreign"',
        'DROP INDEX "users_email_unique"',
        'ALTER TABLE "users" DROP COLUMN "legacy"',
        'ALTER TABLE "users" RENAME COLUMN "name" TO "full_name"',
        'ALTER TABLE "users" ADD COLUMN "nickname" VARCHAR(255) NULL',
        'ALTER TABLE "users" ALTER COLUMN "age" TYPE INTEGER',
        'ALTER TABLE "users" ALTER COLUMN "age" DROP NOT NULL',
        'ALTER TABLE "users" ALTER COLUMN "age" DROP DEFAULT',
        'ALTER TABLE "users" ADD CONSTRAINT "users_team_id_foreign" FOREIGN KEY ("team_id") REFERENCES "teams" ("id") ON DELETE SET NULL',
        'CREATE INDEX "users_age_index" ON "users" ("age")',
      ]);
      final my = const MySqlSchemaGrammar().compileAlter(bp);
      expect(
        my,
        contains(
          'ALTER TABLE `users` DROP FOREIGN KEY `users_team_id_foreign`',
        ),
      );
      expect(my, contains('DROP INDEX `users_email_unique` ON `users`'));
      expect(my, contains('ALTER TABLE `users` MODIFY `age` INT NULL'));
    });

    test('foreign table guessing and identifier validation', () {
      expect(ForeignIdDefinition.guessTable('user_id'), 'users');
      expect(ForeignIdDefinition.guessTable('category_id'), 'categories');
      expect(ForeignIdDefinition.guessTable('address_id'), 'addresses');
      expect(
        () => const SqliteSchemaGrammar().wrap('x; drop'),
        throwsArgumentError,
      );
    });
  });

  group('sqlite execution', () {
    test('create with constraints, introspection, rename and fresh', () async {
      await schema.create('teams', (t) {
        t.id();
        t.string('name').unique();
      });
      await schema.create('users', (t) {
        t.id();
        t.string('email').unique();
        t.foreignId('team_id').nullable().constrained().nullOnDelete();
        t.integer('score').defaultTo(0);
        t.timestamps();
      });
      expect(await schema.hasTable('users'), isTrue);
      expect(await schema.hasColumn('users', 'email'), isTrue);
      expect(await schema.hasColumns('users', ['email', 'nope']), isFalse);
      final columns = await schema.getColumns('users');
      expect(columns.map((c) => c.name), [
        'id',
        'email',
        'team_id',
        'score',
        'created_at',
        'updated_at',
      ]);
      expect(columns.first.autoIncrement, isTrue);
      expect(columns.first.primary, isTrue);
      expect(columns[2].nullable, isTrue);
      expect(columns[3].defaultValue, '0');
      expect((await schema.getTables())..sort(), ['teams', 'users']);

      await db.table('teams').insert({'name': 'red'});
      await db.table('users').insert({'email': 'a@x.test', 'team_id': 1});
      await db.table('teams').delete();
      expect(
        (await db.table('users').first())?['team_id'],
        isNull,
        reason: 'ON DELETE SET NULL',
      );

      await schema.rename('users', 'people');
      expect(await schema.hasTable('people'), isTrue);

      final migrator = Migrator(db, const []);
      await migrator.install();
      expect(await migrator.fresh(), isEmpty);
      expect(await schema.getTables(), ['migrations']);
    });

    test('alter: add/rename/drop columns and indexes', () async {
      await schema.create('items', (t) {
        t.id();
        t.string('name');
        t.integer('qty').defaultTo(1);
      });
      await db.table('items').insert({'name': 'a', 'qty': 3});

      await schema.table('items', (t) {
        t.string('sku').nullable();
        t.renameColumn('qty', 'quantity');
        t.index(['name']);
      });
      await schema.table('items', (t) => t.dropColumn('sku'));

      final columns = await schema.getColumns('items');
      expect(columns.map((c) => c.name), ['id', 'name', 'quantity']);
      expect((await db.table('items').first())?['quantity'], 3);
      final indexes = await db.select('PRAGMA index_list("items")');
      expect(indexes.map((i) => i['name']), contains('items_name_index'));
    });

    test('alter via table rebuild: change, unique, foreign keys and data retention', () async {
      await schema.create('teams', (t) {
        t.id();
        t.string('name');
      });
      await schema.create('members', (t) {
        t.id();
        t.string('email');
        t.integer('team_id').nullable();
        t.string('nickname').nullable();
        t.integer('age').nullable();
      });
      await db.table('teams').insert({'name': 'blue'});
      await db.table('members').insert({
        'email': 'm@x.test',
        'team_id': 1,
        'nickname': 'm',
        'age': 30,
      });

      await schema.table('members', (t) {
        t.string('email').change(); // keep type, now unique via index below
        t.unique(['email']);
        t.foreign(['team_id']).references('id').on('teams').cascadeOnDelete();
        t.dropColumn('nickname');
        t.renameColumn('age', 'years');
        t.boolean('active').defaultTo(true);
      });

      final columns = await schema.getColumns('members');
      expect(columns.map((c) => c.name), [
        'id',
        'email',
        'team_id',
        'years',
        'active',
      ]);
      final row = await db.table('members').sole();
      expect(row['years'], 30);
      expect(row['active'], 1);
      expect(row['email'], 'm@x.test');
      expect(columns.first.autoIncrement, isTrue);

      await expectLater(
        db.table('members').insert({'email': 'm@x.test'}),
        throwsA(anything),
        reason: 'unique',
      );
      await db.table('teams').delete();
      expect(
        await db.table('members').count(),
        0,
        reason: 'cascade delete through rebuilt FK',
      );

      await schema.table('members', (t) {
        t.dropForeign(['team_id']);
        t.dropUnique('members_email_unique');
      });
      await db.table('members').insert({'email': 'dup@x.test', 'team_id': 999});
      await db.table('members').insert({'email': 'dup@x.test', 'team_id': 999});
      expect(await db.table('members').count(), 2);
    });

    test(
      'rebuild inside a migration transaction with referencing tables',
      () async {
        await schema.create('authors', (t) {
          t.id();
          t.string('name');
        });
        await schema.create('books', (t) {
          t.id();
          t.foreignId('author_id').constrained('authors');
          t.string('title');
        });
        await db.table('authors').insert({'name': 'A'});
        await db.table('books').insert({'author_id': 1, 'title': 'T'});
        await db.transaction(() async {
          await SchemaBuilder(await db.executor()).table('authors', (t) {
            t.string('bio').nullable();
            t.string('name').nullable().change();
          });
        });
        expect(await schema.hasColumn('authors', 'bio'), isTrue);
        expect(await db.table('books').count(), 1);
        expect((await db.table('authors').first())?['name'], 'A');
      },
    );
  });
}
