import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

DatabaseManager _manager() => DatabaseManager(
  const DatabaseConfig(
    defaultConnection: 'sqlite',
    connections: {
      'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
      'pgsql': ConnectionConfig(driver: 'pgsql', database: 'x'),
      'mysql': ConnectionConfig(driver: 'mysql', database: 'x'),
    },
  ),
);

void main() {
  late DatabaseManager db;

  setUp(() async {
    db = _manager();
    await db.statement(
      'CREATE TABLE users ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT, "email" TEXT UNIQUE, "age" INTEGER, "team_id" INTEGER, "meta" TEXT, "created_at" TEXT)',
    );
    await db.statement(
      'CREATE TABLE teams ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT)',
    );
    await db.table('teams').insert([
      {'name': 'red'},
      {'name': 'blue'},
    ]);
    await db.table('users').insert([
      {
        'name': 'Ana',
        'email': 'ana@x.test',
        'age': 30,
        'team_id': 1,
        'meta': '["a","b"]',
        'created_at': '2026-01-05 10:00:00',
      },
      {
        'name': 'Bo',
        'email': 'bo@x.test',
        'age': 25,
        'team_id': 1,
        'meta': '["b"]',
        'created_at': '2026-02-05 10:00:00',
      },
      {
        'name': 'Cy',
        'email': 'cy@x.test',
        'age': 41,
        'team_id': 2,
        'meta': '[]',
        'created_at': '2026-03-05 10:00:00',
      },
      {
        'name': 'Di',
        'email': null,
        'age': null,
        'team_id': null,
        'meta': null,
        'created_at': null,
      },
    ]);
  });

  tearDown(() => db.closeAll());

  group('grammar snapshots', () {
    test('sqlite, postgres and mysql compile the same AST differently', () {
      QueryBuilder build(String conn) => db
          .table('users', connection: conn)
          .select(['id', 'users.name as n'])
          .where('age', '>', 18)
          .whereIn('team_id', [1, 2])
          .orWhereNull('email')
          .orderByDesc('id')
          .limit(5)
          .offset(10);

      expect(
        build('sqlite').toSql(),
        'SELECT "id", "users"."name" AS "n" FROM "users" WHERE "age" > ? AND "team_id" IN (?, ?) OR "email" IS NULL ORDER BY "id" DESC LIMIT ? OFFSET ?',
      );
      expect(
        build('pgsql').toSql(),
        r'SELECT "id", "users"."name" AS "n" FROM "users" WHERE "age" > $1 AND "team_id" IN ($2, $3) OR "email" IS NULL ORDER BY "id" DESC LIMIT $4 OFFSET $5',
      );
      expect(
        build('mysql').toSql(),
        'SELECT `id`, `users`.`name` AS `n` FROM `users` WHERE `age` > ? AND `team_id` IN (?, ?) OR `email` IS NULL ORDER BY `id` DESC LIMIT ? OFFSET ?',
      );
      expect(build('pgsql').getBindings(), [18, 1, 2, 5, 10]);
      expect(build('sqlite').toRawSql(), contains('"age" > 18'));
    });

    test('upsert, insert-ignore and locks differ per dialect', () {
      final pg = const PostgresQueryGrammar().compileUpsert(
        'users',
        [
          {'email': 'a', 'name': 'A'},
        ],
        ['email'],
        ['name'],
      );
      expect(
        pg.sql,
        r'INSERT INTO "users" ("email", "name") VALUES ($1, $2) ON CONFLICT ("email") DO UPDATE SET "name" = excluded."name"',
      );
      final my = const MySqlQueryGrammar().compileUpsert(
        'users',
        [
          {'email': 'a', 'name': 'A'},
        ],
        ['email'],
        ['name'],
      );
      expect(
        my.sql,
        'INSERT INTO `users` (`email`, `name`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `name` = VALUES(`name`)',
      );
      expect(
        const SqliteQueryGrammar().compileInsert('t', [
          {'a': 1},
        ], ignore: true).sql,
        startsWith('INSERT OR IGNORE'),
      );
      expect(
        const PostgresQueryGrammar().compileInsert('t', [
          {'a': 1},
        ], ignore: true).sql,
        endsWith('ON CONFLICT DO NOTHING'),
      );
      expect(
        db.table('users', connection: 'pgsql').lockForUpdate().toSql(),
        endsWith(' FOR UPDATE'),
      );
      expect(
        db.table('users', connection: 'mysql').sharedLock().toSql(),
        endsWith(' LOCK IN SHARE MODE'),
      );
      expect(
        db.table('users', connection: 'sqlite').lockForUpdate().toSql(),
        isNot(contains('FOR UPDATE')),
      );
    });

    test('identifiers are validated', () {
      expect(
        () => db.table('users').select(['name; DROP TABLE users']).toSql(),
        throwsArgumentError,
      );
      expect(
        () => db.table('users').orderBy('id', 'sideways'),
        throwsArgumentError,
      );
    });
  });

  group('reads', () {
    test('where variants, joins, aggregates and ordering', () async {
      expect(
        (await db
            .table('users')
            .where('age', '>=', 30)
            .orderBy('age')
            .pluck('name')),
        ['Ana', 'Cy'],
      );
      expect((await db.table('users').whereBetween('age', 20, 35).count()), 2);
      expect((await db.table('users').whereNull('email').count()), 1);
      expect(
        (await db.table('users').whereNotNull('email').whereNotIn('team_id', [
          2,
        ]).count()),
        2,
      );
      expect((await db.table('users').whereLike('name', 'a%').count()), 1);
      expect(
        (await db
            .table('users')
            .whereYear('created_at', 2026)
            .whereMonth('created_at', '>=', 2)
            .count()),
        2,
      );
      expect(
        (await db.table('users').whereJsonContains('meta', 'b').count()),
        2,
      );
      expect(
        (await db.table('users').whereJsonLength('meta', '>', 1).count()),
        1,
      );
      expect(
        (await db
            .table('users')
            .where(
              (QueryBuilder q) =>
                  q.where('age', '<', 26).orWhere('age', '>', 40),
            )
            .whereNotNull('email')
            .pluck('name')),
        ['Bo', 'Cy'],
      );
      expect(
        (await db
            .table('users')
            .whereAny(['name', 'email'], 'like', '%cy%')
            .count()),
        1,
      );
      expect(
        (await db.table('users').where({'name': 'Ana', 'team_id': 1}).exists()),
        isTrue,
      );
      expect(
        (await db
            .table('users')
            .whereIn(
              'team_id',
              db.table('teams').select(['id']).where('name', 'red'),
            )
            .count()),
        2,
      );
      expect(
        (await db
            .table('users')
            .whereExists(
              db.table('teams').whereColumn('teams.id', '=', 'users.team_id'),
            )
            .count()),
        3,
      );

      final joined = await db
          .table('users')
          .join('teams', 'users.team_id', '=', 'teams.id')
          .select(['users.name', 'teams.name as team'])
          .orderBy('users.id')
          .get();
      expect(joined.map((r) => '${r['name']}@${r['team']}'), [
        'Ana@red',
        'Bo@red',
        'Cy@blue',
      ]);
      final left = await db
          .table('users')
          .leftJoin(
            'teams',
            (JoinBuilder j) => j
                .on('users.team_id', '=', 'teams.id')
                .where('teams.name', '=', 'red'),
          )
          .select(['users.name', 'teams.name as team'])
          .orderBy('users.id')
          .get();
      expect(left.map((r) => r['team']), ['red', 'red', null, null]);

      expect(await db.table('users').sum('age'), 96);
      expect(await db.table('users').avg('age'), 32);
      expect(await db.table('users').max('age'), 41);
      expect(await db.table('users').min('name'), 'Ana');
      final grouped = await db
          .table('users')
          .select(['team_id'])
          .selectRaw('COUNT(*) AS c')
          .whereNotNull('team_id')
          .groupBy(['team_id'])
          .having(DB.raw('COUNT(*)'), '>', 1)
          .get();
      expect(grouped, [
        {'team_id': 1, 'c': 2},
      ]);
      expect(
        (await db
                .table('users')
                .distinct()
                .select(['team_id'])
                .whereNotNull('team_id')
                .get())
            .length,
        2,
      );
      expect(
        (await db.table('users').latest('created_at').value<String>('name')),
        'Cy',
      );
      expect((await db.table('users').find(2))?['name'], 'Bo');
      expect(
        await db.table('users').where('name', 'Ana').pluck('email', 'id'),
        {1: 'ana@x.test'},
      );
      expect(
        () => db.table('users').where('name', 'nobody').firstOrFail(),
        throwsA(isA<RecordNotFoundException>()),
      );
      expect(
        () => db.table('users').whereNotNull('team_id').sole(),
        throwsA(isA<MultipleRecordsFoundException>()),
      );
      expect(
        (await db.table('users').where('name', 'Bo').sole())['name'],
        'Bo',
      );
      final union = await db
          .table('users')
          .select(['name'])
          .where('name', 'Ana')
          .union(db.table('users').select(['name']).where('name', 'Cy'))
          .get();
      expect(union.map((r) => r['name']), unorderedEquals(['Ana', 'Cy']));
      expect(
        (await db
            .table('users')
            .when(
              false,
              (q) => q.where('name', 'x'),
              (q) => q.where('name', 'Ana'),
            )
            .count()),
        1,
      );
    });

    test('paginators serialize like Laravel', () async {
      final page = await db
          .table('users')
          .orderBy('id')
          .paginate(page: 2, perPage: 3, path: '/users', query: {'q': 'x'});
      final json = page.toJson();
      expect(json['total'], 4);
      expect(json['last_page'], 2);
      expect(json['from'], 4);
      expect(json['to'], 4);
      expect(json['next_page_url'], isNull);
      expect(json['prev_page_url'], '/users?q=x&page=1');
      expect((json['links']! as List<Object?>).length, 4);
      expect(
        jsonDecode(Response.encodeJson(page)),
        isA<Map<String, Object?>>(),
      );

      final simple = await db
          .table('users')
          .orderBy('id')
          .simplePaginate(page: 1, perPage: 3);
      expect(simple.hasMorePages, isTrue);
      expect(simple.items.length, 3);

      final first = await db
          .table('users')
          .orderBy('id')
          .cursorPaginate(perPage: 2);
      expect(first.items.map((r) => r['id']), [1, 2]);
      expect(first.previousCursor, isNull);
      final second = await db
          .table('users')
          .orderBy('id')
          .cursorPaginate(perPage: 2, cursor: first.nextCursor);
      expect(second.items.map((r) => r['id']), [3, 4]);
      expect(second.nextCursor, isNull);
      final back = await db
          .table('users')
          .orderBy('id')
          .cursorPaginate(perPage: 2, cursor: second.previousCursor);
      expect(back.items.map((r) => r['id']), [1, 2]);
      expect(Cursor.decode(first.nextCursor!.encode())!.values, {'id': 2});
      expect(() => db.table('users').cursorPaginate(), throwsStateError);
    });

    test('chunk, chunkById and lazy', () async {
      final seen = <Object?>[];
      await db
          .table('users')
          .orderBy('id')
          .chunk(3, (rows, page) => seen.addAll(rows.map((r) => r['id'])));
      expect(seen, [1, 2, 3, 4]);
      final byId = <Object?>[];
      await db
          .table('users')
          .chunkById(2, (rows) => byId.addAll(rows.map((r) => r['id'])));
      expect(byId, [1, 2, 3, 4]);
      expect(
        await db
            .table('users')
            .orderBy('id')
            .lazy(2)
            .map((r) => r['id'])
            .toList(),
        [1, 2, 3, 4],
      );
    });
  });

  group('writes', () {
    test(
      'insert/update/delete/upsert/increment/updateOrInsert/truncate',
      () async {
        final id = await db.table('users').insertGetId({
          'name': 'Ed',
          'email': 'ed@x.test',
          'age': 1,
        });
        expect(id, 5);
        expect(await db.table('users').where('id', id).update({'age': 2}), 1);
        expect(await db.table('users').where('id', id).increment('age', 3), 1);
        expect((await db.table('users').find(id))?['age'], 5);
        expect(
          await db.table('users').where('id', id).decrement('age', 1, {
            'name': 'Edd',
          }),
          1,
        );
        expect((await db.table('users').find(id))?['name'], 'Edd');

        expect(
          await db.table('users').insertOrIgnore({
            'name': 'Dup',
            'email': 'ed@x.test',
          }),
          0,
        );
        await db.table('users').upsert(
          {'email': 'ed@x.test', 'name': 'Upserted', 'age': 9},
          ['email'],
          ['name'],
        );
        final upserted = await db
            .table('users')
            .where('email', 'ed@x.test')
            .sole();
        expect(upserted['name'], 'Upserted');
        expect(upserted['age'], 4);

        expect(
          await db
              .table('users')
              .updateOrInsert({'email': 'new@x.test'}, {'name': 'New'}),
          isTrue,
        );
        expect(
          (await db
              .table('users')
              .where('email', 'new@x.test')
              .first())?['name'],
          'New',
        );
        expect(
          await db
              .table('users')
              .updateOrInsert({'email': 'new@x.test'}, {'name': 'Newer'}),
          isTrue,
        );
        expect(
          (await db
              .table('users')
              .where('email', 'new@x.test')
              .first())?['name'],
          'Newer',
        );

        expect(await db.table('users').delete(id), 1);
        expect(await db.table('users').whereNull('email').delete(), 1);
        await db.table('users').truncate();
        expect(await db.table('users').count(), 0);
      },
    );

    test(
      'raw bindings: positional, named, literals and casts are respected',
      () async {
        expect(
          (await db.select(
            'SELECT name FROM users WHERE age > ? AND name <> ?',
            [26, 'Cy'],
          )).single['name'],
          'Ana',
        );
        expect(
          (await db.select(
            'SELECT name FROM users WHERE age > :min AND age < :max',
            {'min': 20, 'max': 35},
          )).map((r) => r['name']),
          ['Ana', 'Bo'],
        );
        expect(
          (await db.select(
            "SELECT '?' AS q, ':x' AS n, name FROM users WHERE id = :id",
            {'id': 1},
          )).single,
          {'q': '?', 'n': ':x', 'name': 'Ana'},
        );
        final (sql, values) = SqlBindings.expand(
          "SELECT a::int, b FROM t WHERE c = :c AND d = :c -- :ignored\n AND e = ?",
          {'c': 7},
          (i) => '\$$i',
        );
        expect(
          sql,
          'SELECT a::int, b FROM t WHERE c = \$1 AND d = \$2 -- :ignored\n AND e = ?',
        );
        expect(values, [7, 7]);
        expect(
          () => SqlBindings.expand('SELECT ?', [1, 2], (_) => '?'),
          throwsArgumentError,
        );
      },
    );
  });

  group('transactions', () {
    test('savepoints roll back only the nested block', () async {
      await db.transaction(() async {
        await db.table('teams').insert({'name': 'outer'});
        expect(db.transactionDepth, 1);
        await expectLater(
          db.transaction(() async {
            await db.table('teams').insert({'name': 'inner'});
            expect(db.transactionDepth, 2);
            throw StateError('inner fails');
          }),
          throwsStateError,
        );
        await db.transaction(
          () async => db.table('teams').insert({'name': 'inner-ok'}),
        );
      });
      expect(await db.table('teams').pluck('name'), [
        'red',
        'blue',
        'outer',
        'inner-ok',
      ]);
      expect(db.transactionDepth, 0);
    });
  });
}
