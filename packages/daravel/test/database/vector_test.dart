import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
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

void main() {
  group('grammar', () {
    Blueprint items(void Function(Blueprint table) define) {
      final blueprint = Blueprint('items');
      define(blueprint);
      return blueprint;
    }

    test('PostgreSQL', () {
      const grammar = PostgresSchemaGrammar();
      final sql = grammar
          .compileCreate(
            items((table) {
              table.vector('embedding', dimensions: 3);
              table.vector('free');
              table.tsvector('search');
              table.vectorIndex('embedding');
            }),
          )
          .join(';');
      expect(sql, contains('"embedding" vector(3)'));
      expect(sql, contains('"free" vector'));
      expect(sql, contains('"search" tsvector'));
      expect(
        sql,
        contains(
          'CREATE INDEX "items_embedding_vectorindex" ON "items" '
          'USING hnsw ("embedding" vector_cosine_ops)',
        ),
      );
    });

    test('an index on a vector column is a vector index', () {
      final sql = const PostgresSchemaGrammar()
          .compileCreate(
            items((table) {
              table.vector('embedding', dimensions: 3).index();
            }),
          )
          .join(';');
      expect(sql, contains('USING hnsw'));
    });

    test('SQLite keeps the column and leaves the index out', () {
      final sql = const SqliteSchemaGrammar()
          .compileCreate(
            items((table) {
              table.vector('embedding', dimensions: 3);
              table.vectorIndex('embedding');
            }),
          )
          .join(';');
      expect(sql, contains('"embedding" TEXT'));
      expect(sql, isNot(contains('INDEX')));
    });

    test('MariaDB adds its vector index', () {
      final sql = const MySqlSchemaGrammar(SqlDialect.mariadb)
          .compileCreate(
            items((table) {
              table.vector('embedding', dimensions: 3);
              table.vectorIndex('embedding');
            }),
          )
          .join(';');
      expect(sql, contains('`embedding` vector(3)'));
      expect(
        sql,
        contains(
          'ALTER TABLE `items` ADD VECTOR INDEX `items_embedding_vectorindex` '
          '(`embedding`) M=6 DISTANCE=cosine',
        ),
      );
    });

    test('MySQL has the column; its index is refused', () {
      const grammar = MySqlSchemaGrammar();
      expect(
        grammar
            .compileCreate(
              items((table) => table.vector('embedding', dimensions: 3)),
            )
            .join(';'),
        contains('`embedding` vector(3)'),
      );
      expect(
        () => grammar.compileCreate(
          items((table) {
            table.vector('embedding', dimensions: 3);
            table.vectorIndex('embedding');
          }),
        ),
        throwsUnsupportedError,
      );
    });
  });

  group('Cast.vector', () {
    test('reads pgvector text and writes JSON', () {
      expect(Cast.vector.get('[1,2.5,3]'), [1.0, 2.5, 3.0]);
      expect(Cast.vector.get(null), isNull);
      expect(Cast.vector.set([1, 2.5]), '[1.0,2.5]');
      expect(Cast.vector.set(null), isNull);
      expect(() => Cast.vector.set('x'), throwsArgumentError);
    });

    test('MariaDB takes and gives little-endian float32', () {
      const cast = VectorCast();
      final bytes = cast.setFor([1, 0.9], SqlDialect.mariadb)! as Uint8List;
      expect(bytes, hasLength(8));
      expect(bytes.sublist(0, 4), [0, 0, 128, 63]);
      expect(cast.get(bytes), [1.0, 0.9]);
      expect(cast.setFor([1], SqlDialect.postgres), '[1.0]');
      expect(cast.setFor(null, SqlDialect.mariadb), isNull);
    });
  });

  test('distance queries refuse SQLite', () async {
    final base = Directory.systemTemp.createTempSync('daravel_vector');
    addTearDown(() => base.deleteSync(recursive: true));
    final app = Application.configure(basePath: base.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    await app.run(() async {
      expect(
        () => DB.table('x').whereVectorSimilarTo('e', const [1, 2]),
        throwsStateError,
      );
      await expectLater(
        Schema.ensureVectorExtensionExists(),
        throwsUnsupportedError,
      );
    });
  });

  group(
    'pgvector',
    () {
      final url = Platform.environment['DARAVEL_TEST_PGVECTOR'];
      Application? app;

      setUp(() async {
        final uri = Uri.parse(url!);
        final user = uri.userInfo.split(':');
        final base = Directory.systemTemp.createTempSync('daravel_vector');
        addTearDown(() => base.deleteSync(recursive: true));
        app = Application.configure(basePath: base.path)
            .withEnv({
              'APP_ENV': 'testing',
              'DB_CONNECTION': 'pgsql',
              'DB_HOST': uri.host,
              'DB_PORT': '${uri.port}',
              'DB_DATABASE': uri.path.replaceFirst('/', ''),
              'DB_USERNAME': user.first,
              'DB_PASSWORD': user[1],
              'DB_SSLMODE': 'disable',
            })
            .withLogLevel(LogLevel.critical)
            .create();
        await app!.boot();
        addTearDown(app!.shutdown);
        await app!.run(() async {
          await Schema.ensureVectorExtensionExists();
          await Schema.dropIfExists('vector_items');
          await Schema.create('vector_items', (table) {
            table.id();
            table.vector('embedding', dimensions: 3);
            table.tsvector('search').nullable();
            table.vectorIndex('embedding');
          });
          await Item.definition.query().create({
            'embedding': [1, 0, 0],
          });
          await Item.definition.query().create({
            'embedding': [0.9, 0.1, 0],
          });
          await Item.definition.query().create({
            'embedding': [0, 0, 1],
          });
        });
      });

      test('the cast reads what it wrote', () async {
        await app!.run(() async {
          final item = await Item.definition.query().orderBy('id').first();
          expect(item!.getAttr<List<double>>('embedding'), [1.0, 0.0, 0.0]);
          final second = await Item.definition.query().find(2);
          expect(second!.getAttr<List<double>>('embedding'), [0.9, 0.1, 0.0]);
        });
      });

      test('whereVectorSimilarTo filters and sorts by distance', () async {
        await app!.run(() async {
          final rows = await DB.table('vector_items').whereVectorSimilarTo(
            'embedding',
            const [1, 0, 0],
          ).get();
          expect([for (final r in rows) r['id']], [1, 2]);
        });
      });

      test('selectVectorDistance adds the distance', () async {
        await app!.run(() async {
          final row = await DB
              .table('vector_items')
              .select(['id'])
              .selectVectorDistance('embedding', const [1, 0, 0])
              .where('id', 3)
              .first();
          expect(row!['embedding_distance'], closeTo(1, 0.0001));
        });
      });

      test('orderByVectorDistance has no filter', () async {
        await app!.run(() async {
          final rows = await DB.table('vector_items').orderByVectorDistance(
            'embedding',
            const [0, 0, 1],
          ).get();
          expect(rows.first['id'], 3);
          expect(rows, hasLength(3));
        });
      });
    },
    skip: Platform.environment['DARAVEL_TEST_PGVECTOR'] == null
        ? 'needs DARAVEL_TEST_PGVECTOR'
        : false,
  );
}
