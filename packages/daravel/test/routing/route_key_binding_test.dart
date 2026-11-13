import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class Item extends Model {
  static final ModelDefinition<Item> definition = ModelDefinition<Item>(
    table: 'rk_items',
    factory: Item.new,
    timestamps: false,
  );
  @override
  ModelDefinition<Item> get modelDefinition => definition;
}

/// The same table, bound by its integer `number` column (`routeKey:`).
final class NumberedItem extends Model {
  static final ModelDefinition<NumberedItem> definition =
      ModelDefinition<NumberedItem>(
        table: 'rk_items',
        factory: NumberedItem.new,
        timestamps: false,
        routeKey: 'number',
      );
  @override
  ModelDefinition<NumberedItem> get modelDefinition => definition;
}

/// Route model binding by a column that is not text, with a value from the
/// URL that is not a number (`/by-number/abc`): on SQLite and (with
/// `DARAVEL_TEST_PG`) PostgreSQL, which refuses to compare an integer
/// column with `'abc'`. The MySQL run is in `daravel_mysql`.
void main() {
  final pg = Platform.environment['DARAVEL_TEST_PG'];
  final runs = <String, Map<String, String> Function()>{
    'SQLite': () => {
      'DB_CONNECTION': 'sqlite',
      'DB_DATABASE': p.join(
        Directory.systemTemp.createTempSync('route_key_').path,
        'db.sqlite',
      ),
    },
    if (pg != null && pg.isNotEmpty)
      'PostgreSQL': () => {'DB_CONNECTION': 'pgsql', 'DB_URL': pg},
  };
  for (final MapEntry(key: name, value: env) in runs.entries) {
    group(name, () {
      late Application app;
      late TestClient client;
      setUp(() async {
        app = Application.configure(basePath: Directory.systemTemp.path)
            .withEnv({'APP_ENV': 'testing', ...env()})
            .withLogLevel(LogLevel.critical)
            .withRouting(
              web: (router) {
                router
                  ..bindModel('item', Item.definition)
                  ..bindModel('numbered', NumberedItem.definition);
                Map<String, Object?> id(Request r, String param) => {
                  'id': r.binding<Model>(param).getAttr<Object?>('id'),
                };
                router.get('/by-number/{item:number}', (r) => id(r, 'item'));
                router.get('/numbered/{numbered}', (r) => id(r, 'numbered'));
              },
            )
            .create();
        await app.boot();
        await app.run(() async {
          final schema = await Schema.builder();
          await schema.dropIfExists('rk_items');
          await schema.create('rk_items', (table) {
            table.id();
            table.integer('number');
          });
          await DB.table('rk_items').insert([
            {'number': 0},
            {'number': 7},
          ]);
        });
        client = TestClient(app);
      });
      tearDown(() async {
        await app.run(
          () async => (await Schema.builder()).dropIfExists('rk_items'),
        );
        await app.shutdown();
      });

      test('a binding field on an integer column: a word is a 404', () async {
        (await client.get('/by-number/7')).assertOk();
        expect((await client.get('/by-number/abc')).status, 404);
      });

      test('a route key on an integer column: a word is a 404', () async {
        (await client.get('/numbered/7')).assertOk();
        expect((await client.get('/numbered/abc')).status, 404);
      });
    });
  }
}
