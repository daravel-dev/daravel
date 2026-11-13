import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:daravel_test/daravel_test.dart';
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

/// The MySQL run of `daravel`'s `test/routing/route_key_binding_test.dart`:
/// MySQL compares an integer column with `'abc'` as with `0`, so a word in
/// the URL must not find the row whose number is 0. Runs only with
/// `DARAVEL_TEST_MYSQL`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_MYSQL'];
  group('MySQL', () {
    late Application app;
    late TestClient client;
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
  }, skip: url == null || url.isEmpty ? 'needs DARAVEL_TEST_MYSQL' : false);
}
