@Tags(['security'])
library;

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// The structural arguments of a query, `boolean` and `operator`, are
/// written into the SQL text, so every method that takes one refuses
/// anything outside its whitelist, and the grammar writes only whitelisted
/// tokens even for a hand-built AST. Values stay bound.
void main() {
  late DatabaseManager db;

  setUp(() {
    db = DatabaseManager(
      const DatabaseConfig(
        defaultConnection: 'sqlite',
        connections: {
          'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
        },
      ),
    );
  });

  QueryBuilder users() => db.table('users');

  const booleans = <String>[
    'OR 1=1',
    'AND 1=1; DROP TABLE users; --',
    'OR 1=1 --',
    'XOR',
    'AND/**/',
    '',
  ];

  const operators = <String>[
    '= 1; DROP TABLE users; --',
    'OR 1=1',
    '= 1 OR 1 =',
    'SOUNDS LIKE',
    'LIKE OR 1=1',
    '=/**/',
    '',
  ];

  // Each builds a query whose last condition carries the boolean, after a
  // first one, so the boolean is written into the SQL.
  QueryBuilder first() => users().where('id', 0);
  final byBoolean = <String, QueryBuilder Function(String)>{
    'where': (b) => first().where('id', '=', 1, b),
    'where (map)': (b) => first().where({'id': 1}, null, null, b),
    'where (nested)': (b) =>
        first().where((QueryBuilder n) => n.where('id', 1), null, null, b),
    'whereNot': (b) =>
        first().whereNot((QueryBuilder n) => n.where('id', 1), b),
    'whereColumn': (b) => first().whereColumn('id', '=', 'team_id', b),
    'whereIn': (b) => first().whereIn('id', [1, 2], boolean: b),
    'whereIn (subquery)': (b) =>
        first().whereIn('id', db.table('teams').select(['id']), boolean: b),
    'whereNull': (b) => first().whereNull('id', boolean: b),
    'whereBetween': (b) => first().whereBetween('id', 1, 2, boolean: b),
    'whereExists': (b) => first().whereExists(db.table('teams'), boolean: b),
    'whereRaw': (b) => first().whereRaw('id = ?', [1], b),
    'whereLike': (b) => first().whereLike('name', 'a%', boolean: b),
    'having': (b) =>
        users().groupBy(['id']).having('id', '>', 0).having('id', '=', 1, b),
    'JoinBuilder.on': (b) => users().join(
      'teams',
      (JoinBuilder j) => j
          .on('users.team_id', '=', 'teams.id')
          .on('users.id', '=', 'teams.id', b),
    ),
    'JoinBuilder.where': (b) => users().join(
      'teams',
      (JoinBuilder j) =>
          j.on('users.team_id', '=', 'teams.id').where('teams.id', '=', 1, b),
    ),
  };

  group('boolean is AND or OR on every method that takes one', () {
    for (final MapEntry(key: name, value: build) in byBoolean.entries) {
      test(name, () {
        for (final payload in booleans) {
          expect(
            () => build(payload),
            throwsArgumentError,
            reason: '$name with boolean "$payload"',
          );
        }
        // Accepted in any case, and written as before: AND or OR.
        final and = build('AND').toSql();
        expect(and, contains(' AND '), reason: name);
        expect(build('and').toSql(), and, reason: name);
        final or = build('OR').toSql();
        expect(or, contains(' OR '), reason: name);
        expect(build('or').toSql(), or, reason: name);
      });
    }
  });

  final byOperator = <String, QueryBuilder Function(String)>{
    'where': (o) => users().where('id', o, 1),
    'orWhere': (o) => first().orWhere('id', o, 1),
    'where (nested)': (o) =>
        users().where((QueryBuilder n) => n.where('id', o, 1)),
    'whereColumn': (o) => users().whereColumn('id', o, 'team_id'),
    'having': (o) => users().groupBy(['id']).having('id', o, 1),
    'orHaving': (o) =>
        users().groupBy(['id']).having('id', '>', 0).orHaving('id', o, 1),
    'join': (o) => users().join('teams', 'users.team_id', o, 'teams.id'),
    'leftJoin': (o) =>
        users().leftJoin('teams', 'users.team_id', o, 'teams.id'),
    'rightJoin': (o) =>
        users().rightJoin('teams', 'users.team_id', o, 'teams.id'),
    'joinSub': (o) =>
        users().joinSub(db.table('teams'), 't', 'users.team_id', o, 't.id'),
    'JoinBuilder.on': (o) => users().join(
      'teams',
      (JoinBuilder j) => j.on('users.team_id', o, 'teams.id'),
    ),
    'JoinBuilder.orOn': (o) => users().join(
      'teams',
      (JoinBuilder j) => j
          .on('users.team_id', '=', 'teams.id')
          .orOn('users.id', o, 'teams.id'),
    ),
    'JoinBuilder.where': (o) =>
        users().join('teams', (JoinBuilder j) => j.where('teams.id', o, 1)),
    'whereDate': (o) => users().whereDate('created_at', o, '2026-01-01'),
    'whereJsonLength': (o) => users().whereJsonLength('meta', o, 2),
  };

  group('operator is whitelisted on every method that takes one', () {
    for (final MapEntry(key: name, value: build) in byOperator.entries) {
      test(name, () {
        for (final payload in operators) {
          expect(
            () => build(payload),
            throwsArgumentError,
            reason: '$name with operator "$payload"',
          );
        }
        // Accepted in any case; `!=` is written `<>`, as `where` did.
        expect(build('like').toSql(), build('LIKE').toSql(), reason: name);
        expect(build('like').toSql(), contains(' LIKE '), reason: name);
        expect(build('!=').toSql(), build('<>').toSql(), reason: name);
        expect(build('>=').toSql(), contains(' >= '), reason: name);
      });
    }
  });

  test('accepted forms are written normalized', () {
    expect(
      users()
          .where('id', 1)
          .where('team_id', '=', 2, 'or')
          .whereColumn('id', '!=', 'team_id')
          .toSql(),
      'SELECT * FROM "users" WHERE "id" = ? OR "team_id" = ? '
      'AND "id" <> "team_id"',
    );
    expect(
      users()
          .groupBy(['name'])
          .having('name', 'like', 'a%')
          .having('id', '>', 1, 'Or')
          .toSql(),
      'SELECT * FROM "users" GROUP BY "name" HAVING "name" LIKE ? OR "id" > ?',
    );
    expect(
      users()
          .join(
            'teams',
            (JoinBuilder j) =>
                j.on('users.team_id', '=', 'teams.id').orOn('a', '<>', 'b'),
          )
          .toSql(),
      'SELECT * FROM "users" INNER JOIN "teams" ON "users"."team_id" = '
      '"teams"."id" OR "a" <> "b"',
    );
  });

  group('the grammar writes only whitelisted tokens (hand-built AST)', () {
    const grammar = SqliteQueryGrammar();

    test('a where boolean', () {
      final ast = QueryAst('users')
        ..wheres.addAll(const [
          BasicWhere('id', '=', 1),
          BasicWhere('id', '=', 2, boolean: 'OR 1=1 --'),
        ]);
      expect(() => grammar.compileSelect(ast), throwsArgumentError);
      final x = QueryAst('users')
        ..wheres.addAll(const [
          BasicWhere('id', '=', 1),
          NullWhere('team_id', boolean: 'x'),
        ]);
      expect(() => grammar.compileSelect(x), throwsArgumentError);
    });

    test('a where operator', () {
      final ast = QueryAst('users')
        ..wheres.add(const BasicWhere('id', '= 1; DROP TABLE users; --', 1));
      expect(() => grammar.compileSelect(ast), throwsArgumentError);
      final column = QueryAst('users')
        ..wheres.add(const ColumnWhere('id', 'OR 1=1', 'team_id'));
      expect(() => grammar.compileSelect(column), throwsArgumentError);
    });

    test('a having boolean and operator', () {
      final boolean = QueryAst('users')
        ..havings.addAll([
          HavingClause('id', '=', 1),
          HavingClause('id', '=', 2, boolean: 'OR 1=1'),
        ]);
      expect(() => grammar.compileSelect(boolean), throwsArgumentError);
      final operator = QueryAst('users')
        ..havings.add(HavingClause('id', '> 0 OR 1=1 --', 1));
      expect(() => grammar.compileSelect(operator), throwsArgumentError);
    });

    test('a join boolean and operator', () {
      JoinClause join(String operator, String boolean) =>
          JoinClause(type: JoinType.inner, table: 'teams')
            ..conditions.addAll([
              JoinCondition(first: 'a', operator: '=', second: 'b'),
              JoinCondition(
                first: 'c',
                operator: operator,
                second: 'd',
                boolean: boolean,
              ),
            ]);
      expect(
        () => grammar.compileSelect(
          QueryAst('users')..joins.add(join('=', 'OR 1=1')),
        ),
        throwsArgumentError,
      );
      expect(
        () => grammar.compileSelect(
          QueryAst('users')
            ..joins.add(join('= 1; DROP TABLE users; --', 'AND')),
        ),
        throwsArgumentError,
      );
    });
  });
}
