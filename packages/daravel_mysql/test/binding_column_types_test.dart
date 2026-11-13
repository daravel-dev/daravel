import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:test/test.dart';

final class Owner extends Model {
  static final ModelDefinition<Owner> definition = ModelDefinition<Owner>(
    table: 'bct_owners',
    factory: Owner.new,
    timestamps: false,
    relations: {
      'items': () =>
          HasMany<Item>(() => Item.definition, foreignKey: 'owner_id'),
    },
  );
  @override
  ModelDefinition<Owner> get modelDefinition => definition;
}

final class Item extends Model {
  static final ModelDefinition<Item> definition = ModelDefinition<Item>(
    table: 'bct_items',
    factory: Item.new,
    timestamps: false,
  );
  @override
  ModelDefinition<Item> get modelDefinition => definition;
}

final class _InTransaction implements Middleware {
  const _InTransaction();

  @override
  Future<Response> handle(Request request, Next next) {
    if (!request.path.startsWith('/tx/')) {
      return next(request);
    }
    return DB.transaction(() async {
      final response = await next(request);
      await DB.select('SELECT 1');
      return response;
    });
  }
}

/// The MySQL run of `daravel`'s `test/routing/binding_column_types_test.dart`.
/// MySQL compares an integer column with `'abc'` as with `0` and with
/// `'7abc'` as with `7`, and Laravel binds those rows (the golden); Daravel
/// reads the value as PostgreSQL does and answers 404, on purpose. Runs
/// only with `DARAVEL_TEST_MYSQL`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_MYSQL'];
  final golden =
      (jsonDecode(
            File(
              '../daravel/test/routing/fixtures/'
              'laravel_binding_non_text.json',
            ).readAsStringSync(),
          ) as Map<String, Object?>)['runs']
          as Map<String, Object?>;
  List<Map<String, Object?>> rows(String dialect) => [
    for (final row
        in (golden[dialect] as Map<String, Object?>)['binding field']
            as List<Object?>)
      row as Map<String, Object?>,
  ];
  const uuid7 = '0b9a2f8e-5c1d-4c47-9a3e-2f0d6c7b8a91';

  group('MySQL', () {
    late Application app;

    setUp(() async {
      final uri = Uri.parse(url!);
      final user = uri.userInfo.split(':');
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_CONNECTION': 'mysql',
            'DB_HOST': uri.host,
            'DB_PORT': '${uri.port}',
            'DB_DATABASE': uri.path.replaceFirst('/', ''),
            'DB_USERNAME': user.first,
            'DB_PASSWORD': user.length > 1 ? user[1] : '',
          })
          .withLogLevel(LogLevel.critical)
          .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
          .withMiddleware((m) => m.use(const [_InTransaction()]))
          .withRouting(
            web: (router) {
              router
                ..bindModel('item', Item.definition)
                ..bindModel('owner', Owner.definition);
              Map<String, Object?> found(Request r) => {
                'number': r.binding<Item>('item').getAttr<Object?>('number'),
              };
              for (final column in ['number', 'code', 'day', 'flag', 'label']) {
                router.get('/by-$column/{item:$column}', found);
                router.get('/tx/by-$column/{item:$column}', found);
              }
              router.get('/owners/{owner}/items/{item:number}', found);
            },
          )
          .create();
      await app.boot();
      await app.run(() async {
        final schema = await Schema.builder();
        await schema.dropIfExists('bct_items');
        await schema.dropIfExists('bct_owners');
        await schema.create('bct_owners', (table) => table.id());
        await schema.create('bct_items', (table) {
          table.id();
          table.integer('owner_id');
          table.integer('number');
          table.uuid('code');
          table.date('day');
          table.boolean('flag');
          table.string('label');
        });
        await DB.table('bct_owners').insert([
          {'id': 1},
          {'id': 2},
        ]);
        await DB.table('bct_items').insert([
          {
            'owner_id': 1,
            'number': 0,
            'code': '00000000-0000-4000-8000-000000000000',
            'day': '2026-01-01',
            'flag': false,
            'label': '0',
          },
          {
            'owner_id': 1,
            'number': 7,
            'code': uuid7,
            'day': '2026-01-07',
            'flag': true,
            'label': '007',
          },
        ]);
      });
    });

    tearDown(() async {
      await app.run(() async {
        final schema = await Schema.builder();
        await schema.dropIfExists('bct_items');
        await schema.dropIfExists('bct_owners');
      });
      await app.shutdown();
    });

    /// The status and decoded JSON body of a GET (no test client here:
    /// `daravel_mysql` does not depend on `daravel_test`).
    Future<({int status, Object? json})> get(String path, String value) async {
      final response = await app.handle(
        Request.fake(path: '$path/${Uri.encodeComponent(value)}'),
      );
      final text = await response.bodyText();
      return (
        status: response.status,
        json: response.status == 200 ? jsonDecode(text) : null,
      );
    }

    test('an integer column answers as Laravel on PostgreSQL', () async {
      for (final row in rows('pgsql')) {
        final value = row['value']! as String;
        for (final path in ['/by-number', '/tx/by-number']) {
          final response = await get(path, value);
          if (row['status'] == 200) {
            expect(response.status, 200, reason: '$path "$value"');
            expect(response.json, {'number': row['number']}, reason: value);
          } else {
            expect(response.status, 404, reason: '$path "$value"');
          }
        }
      }
    });

    test('where Laravel on MySQL binds another row, a 404 (on purpose)', () {
      final mysql = {for (final row in rows('mysql')) row['value']: row};
      // The golden this differs from: 'abc' found the row whose number is
      // 0, '7abc' and '7.0' the row whose number is 7.
      expect(mysql['abc'], containsPair('number', 0));
      expect(mysql['7abc'], containsPair('number', 7));
      expect(mysql['7.0'], containsPair('number', 7));
      return Future.wait([
        for (final value in ['abc', '7abc', '7.0'])
          get(
            '/by-number',
            value,
          ).then((response) => expect(response.status, 404, reason: value)),
      ]);
    });

    test('uuid, date, boolean and text columns', () async {
      for (final prefix in ['', '/tx']) {
        for (final (column, value) in [
          ('code', 'abc'),
          ('day', 'abc'),
          ('day', '2026-13-45'),
          ('flag', 'abc'),
          ('label', '7'),
        ]) {
          final response = await get('$prefix/by-$column', value);
          expect(response.status, 404, reason: '$prefix $column "$value"');
        }
        expect((await get('$prefix/by-code', uuid7)).json, {'number': 7});
        expect((await get('$prefix/by-day', '2026-01-07')).json, {'number': 7});
        expect((await get('$prefix/by-label', '007')).json, {'number': 7});
      }
    });

    test('scoped to its parent, by an integer column', () async {
      expect((await get('/owners/1/items', '7')).json, {'number': 7});
      expect((await get('/owners/2/items', '7')).status, 404);
      expect((await get('/owners/1/items', 'abc')).status, 404);
    });
  }, skip: url == null || url.isEmpty ? 'needs DARAVEL_TEST_MYSQL' : false);
}
