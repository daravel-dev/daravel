import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `where('meta->lang', 'id')` and `update({'meta->lang': 'en'})`, as
/// Laravel's grammars compile them. PostgreSQL runs when `DARAVEL_TEST_PG`
/// is set.
void main() {
  group('the SQL of each dialect', () {
    String select(SqlDialect dialect) =>
        QueryGrammar.forDialect(dialect).wrap('meta->a->b');

    test('selectors', () {
      expect(
        select(SqlDialect.sqlite),
        '''json_extract("meta", '\$."a"."b"')''',
      );
      expect(select(SqlDialect.postgres), '''"meta"->'a'->>'b\'''');
      expect(
        select(SqlDialect.mysql),
        '''json_unquote(json_extract(`meta`, '\$."a"."b"'))''',
      );
    });

    test('a table prefix and array indexes', () {
      final pg = QueryGrammar.forDialect(SqlDialect.postgres);
      final sqlite = QueryGrammar.forDialect(SqlDialect.sqlite);
      expect(
        pg.wrap('t.meta->items[0]->id'),
        '''"t"."meta"->'items'->0->>'id\'''',
      );
      expect(
        sqlite.wrap('meta->items[0]->id'),
        '''json_extract("meta", '\$."items"[0]."id"')''',
      );
    });

    test('a path cannot carry SQL', () {
      final grammar = QueryGrammar.forDialect(SqlDialect.postgres);
      for (final selector in [
        "meta->a' OR 1=1 --",
        'meta->a"b',
        'meta->',
        'meta->>a',
        'me ta->a',
      ]) {
        expect(
          () => grammar.wrap(selector),
          throwsArgumentError,
          reason: selector,
        );
      }
    });
  });

  void suite(String name, String jsonType, DatabaseManager Function() open) {
    group(name, () {
      late DatabaseManager db;

      setUp(() async {
        db = open();
        await db.statement('DROP TABLE IF EXISTS json_rows');
        await db.statement(
          'CREATE TABLE json_rows (id INTEGER PRIMARY KEY, meta $jsonType, name TEXT)',
        );
        await db.table('json_rows').insert([
          {
            'id': 1,
            'name': 'a',
            'meta': jsonEncode({
              'lang': 'id',
              'n': {'x': 1},
            }),
          },
          {
            'id': 2,
            'name': 'b',
            'meta': jsonEncode({'lang': 'en'}),
          },
        ]);
      });

      tearDown(() async {
        await db.statement('DROP TABLE IF EXISTS json_rows');
        await db.closeAll();
      });

      Future<Map<String, Object?>> meta(int id) async {
        final row = (await db.table('json_rows').where('id', id).first())!;
        return switch (row['meta']) {
          final String text => jsonDecode(text) as Map<String, Object?>,
          final other => other! as Map<String, Object?>,
        };
      }

      test('where', () async {
        final rows = await db
            .table('json_rows')
            .where('meta->lang', 'id')
            .get();
        expect(rows.single['id'], 1);
      });

      test('where with a number and a boolean', () async {
        await db.table('json_rows').where('id', 2).update({
          'meta->on': true,
          'meta->x': 7,
        });
        final number = await db.table('json_rows').where('meta->x', 7).get();
        expect(number.single['id'], 2);
        final flag = await db.table('json_rows').where('meta->on', true).get();
        expect(flag.single['id'], 2);
      });

      test('orderBy', () async {
        final rows = await db
            .table('json_rows')
            .orderBy('meta->lang', 'desc')
            .get();
        expect([for (final r in rows) r['id']], [1, 2]);
      });

      test('update keeps the other keys, and the JSON types', () async {
        await db.table('json_rows').where('id', 1).update({
          'name': 'z',
          'meta->lang': 'en',
          'meta->flag': true,
          'meta->count': 3,
          'meta->list': [1, 2],
          'meta->n->x': 2,
        });
        expect(await meta(1), {
          'lang': 'en',
          'n': {'x': 2},
          'flag': true,
          'count': 3,
          'list': [1, 2],
        });
        final row = (await db.table('json_rows').where('id', 1).first())!;
        expect(row['name'], 'z');
      });
    });
  }

  suite(
    'sqlite',
    'TEXT',
    () => DatabaseManager(
      DatabaseConfig(
        defaultConnection: 'sqlite',
        connections: {
          'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
        },
      ),
    ),
  );

  final pg = Platform.environment['DARAVEL_TEST_PG'];
  if (pg != null) {
    final url = Uri.parse(pg);
    suite(
      'postgres',
      'JSONB',
      () => DatabaseManager(
        DatabaseConfig(
          defaultConnection: 'pgsql',
          connections: {
            'pgsql': ConnectionConfig(
              driver: 'pgsql',
              host: url.host,
              port: url.port,
              database: url.path.substring(1),
              username: url.userInfo.split(':').first,
              password: url.userInfo.split(':').last,
            ),
          },
        ),
      ),
    );
  }
}
