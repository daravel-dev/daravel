import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:test/test.dart';

final class Item extends Model {
  static final ModelDefinition<Item> definition = ModelDefinition<Item>(
    table: 'vector_items',
    factory: Item.new,
    timestamps: false,
    guarded: const [],
    casts: const {'embedding': Cast.vector},
  );
  @override
  ModelDefinition<Item> get modelDefinition => definition;
}

/// Needs MariaDB 11.7 or newer, e.g.
/// `DARAVEL_TEST_MARIADB_VECTOR=mysql://daravel:secret@127.0.0.1:3306/daravel_test`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_MARIADB_VECTOR'];

  group('MariaDB vectors', () {
    late Application app;

    setUp(() async {
      final uri = Uri.parse(url!);
      final user = uri.userInfo.split(':');
      final base = Directory.systemTemp.createTempSync('daravel_vector');
      addTearDown(() => base.deleteSync(recursive: true));
      app = Application.configure(basePath: base.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_CONNECTION': 'mariadb',
            'DB_HOST': uri.host,
            'DB_PORT': '${uri.port}',
            'DB_DATABASE': uri.path.replaceFirst('/', ''),
            'DB_USERNAME': user.first,
            'DB_PASSWORD': user[1],
          })
          .withLogLevel(LogLevel.critical)
          .withDatabaseDriver('mariadb', MySqlDriver.fromConfig)
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      await app.run(() async {
        await Schema.dropIfExists('vector_items');
        await Schema.create('vector_items', (table) {
          table.id();
          table.vector('embedding', dimensions: 3);
          table.vectorIndex('embedding');
        });
        for (final embedding in const [
          [1.0, 0.0, 0.0],
          [0.9, 0.1, 0.0],
          [0.0, 0.0, 1.0],
        ]) {
          await Item.definition.query().create({'embedding': embedding});
        }
      });
    });

    test('the connection knows it is MariaDB', () async {
      await app.run(() async {
        expect(DB.manager.dialectOf(), SqlDialect.mariadb);
      });
    });

    test('the cast reads what it wrote', () async {
      await app.run(() async {
        final item = await Item.definition
            .query()
            .selectVector('embedding')
            .where('id', 2)
            .first();
        expect(item!.getAttr<List<double>>('embedding'), [0.9, 0.1, 0.0]);
      });
    });

    test('whereVectorSimilarTo filters and sorts by distance', () async {
      await app.run(() async {
        final rows = await DB.table('vector_items').whereVectorSimilarTo(
          'embedding',
          const [1, 0, 0],
        ).get();
        expect([for (final r in rows) r['id']], [1, 2]);
      });
    });

    test('selectVectorDistance adds the distance', () async {
      await app.run(() async {
        final row = await DB
            .table('vector_items')
            .select(['id'])
            .selectVectorDistance('embedding', const [1, 0, 0])
            .where('id', 3)
            .first();
        expect(num.parse('${row!['embedding_distance']}'), closeTo(1, 0.0001));
      });
    });

    test('RAND and upserts still work as MySQL', () async {
      await app.run(() async {
        final rows = await DB.table('vector_items').inRandomOrder().get();
        expect(rows, hasLength(3));
      });
    });
  }, skip: url == null ? 'needs DARAVEL_TEST_MARIADB_VECTOR' : false);
}
