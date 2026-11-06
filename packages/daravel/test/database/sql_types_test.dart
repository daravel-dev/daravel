import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

DatabaseManager _manager() => DatabaseManager(
  const DatabaseConfig(
    defaultConnection: 'sqlite',
    connections: {
      'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
      'pgsql': ConnectionConfig(driver: 'pgsql', database: 'x'),
      'mysql': ConnectionConfig(driver: 'mysql', database: 'x'),
      'mariadb': ConnectionConfig(driver: 'mariadb', database: 'x'),
    },
  ),
);

void main() {
  group('SqlIdentifier', () {
    test('accepts plain and qualified names', () {
      for (final name in ['id', '_x', 'Users', 'users.id', 'app.users.id1']) {
        expect(SqlIdentifier(name), name);
        expect(SqlIdentifier.isValid(name), isTrue);
        expect(SqlIdentifier.tryParse(name), name);
      }
    });

    test('is a String', () {
      final String column = SqlIdentifier('users.id');
      expect(column, 'users.id');
      expect(SqlIdentifier('users.id').split('.'), ['users', 'id']);
      expect(SqlIdentifier('a').name, 'a');
    });

    test('rejects anything but plain names joined by dots', () {
      for (final name in [
        '',
        '1id',
        'users.',
        '.id',
        'users..id',
        'users.*',
        '*',
        'id as x',
        'meta->a',
        'na me',
        'id"; DROP TABLE users; --',
        'id`',
        'ïd',
      ]) {
        expect(
          () => SqlIdentifier(name),
          throwsA(
            isA<ArgumentError>()
                .having((e) => e.name, 'name', 'name')
                .having((e) => e.invalidValue, 'invalidValue', name),
          ),
          reason: name,
        );
        expect(SqlIdentifier.isValid(name), isFalse, reason: name);
        expect(SqlIdentifier.tryParse(name), isNull, reason: name);
      }
    });
  });

  group('SqlFragment', () {
    test('RawExpression.sql is a SqlFragment and a String', () {
      final raw = DB.raw('price * ?', [1.1]);
      final SqlFragment fragment = raw.sql;
      final String text = raw.sql;
      expect(fragment, 'price * ?');
      expect(text, 'price * ?');
      expect('$raw', 'price * ?');
      const constant = RawExpression('COUNT(*)');
      expect(constant.sql, 'COUNT(*)');
    });
  });

  group('builder', () {
    late DatabaseManager db;
    setUp(() => db = _manager());
    tearDown(() => db.closeAll());

    QueryBuilder build(String connection, {required bool typed}) {
      String c(String name) => typed ? SqlIdentifier(name) : name;
      final q = db.table('users', connection: connection);
      return q
          .select([c('users.id'), c('name')])
          .where(c('email'), 'a@x.test')
          .orWhere(c('age'), '>', 18)
          .whereIn(c('users.team_id'), [1, 2])
          .whereNull(c('deleted_at'))
          .whereBetween(c('age'), 1, 9)
          .whereColumn(c('users.id'), '=', c('users.team_id'))
          .whereAny([c('name'), c('email')], 'LIKE', '%a%')
          .groupBy([c('users.team_id')])
          .having(c('age'), '>', 1)
          .orderBy(c('name'))
          .orderByDesc(c('users.id'))
          .latest(c('created_at'));
    }

    for (final connection in ['sqlite', 'pgsql', 'mysql', 'mariadb']) {
      test('$connection: SQL and bindings are identical with either', () {
        final plain = build(connection, typed: false);
        final typed = build(connection, typed: true);
        expect(typed.toSql(), plain.toSql());
        expect(typed.getBindings(), plain.getBindings());
      });
    }

    test('grammars quote a SqlIdentifier as before', () {
      QueryBuilder q(String connection) => db
          .table('users', connection: connection)
          .select([SqlIdentifier('users.id')])
          .where(SqlIdentifier('email'), 'a')
          .orderByDesc(SqlIdentifier('users.name'));
      expect(
        q('sqlite').toSql(),
        'SELECT "users"."id" FROM "users" WHERE "email" = ? '
        'ORDER BY "users"."name" DESC',
      );
      expect(
        q('pgsql').toSql(),
        r'SELECT "users"."id" FROM "users" WHERE "email" = $1 '
        'ORDER BY "users"."name" DESC',
      );
      expect(
        q('mysql').toSql(),
        'SELECT `users`.`id` FROM `users` WHERE `email` = ? '
        'ORDER BY `users`.`name` DESC',
      );
    });

    test('SqlIdentifier columns run like strings', () async {
      await db.statement(
        'CREATE TABLE users ("id" INTEGER PRIMARY KEY, "name" TEXT)',
      );
      await db.table('users').insert([
        {'id': 1, 'name': 'Ana'},
        {'id': 2, 'name': 'Bo'},
      ]);
      final sort = SqlIdentifier('users.name');
      final rows = await db
          .table('users')
          .where(SqlIdentifier('id'), '>', 0)
          .orderByDesc(sort)
          .pluck(SqlIdentifier('name'));
      expect(rows, ['Bo', 'Ana']);
    });
  });
}
