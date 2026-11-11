@Tags(['integration'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_scout/daravel_scout.dart';
import 'package:test/test.dart';

final class Article extends Model with Searchable {
  static final ModelDefinition<Article> definition = ModelDefinition<Article>(
    table: 'scout_articles',
    factory: Article.new,
    timestamps: false,
    casts: const {'embedding': Cast.vector},
  );

  @override
  ModelDefinition<Article> get modelDefinition => definition;

  @override
  Map<String, Object?> toSearchableArray() => const {
    'title': null,
    'body': null,
  };

  @override
  List<String> get searchUsingFullText => const ['body'];

  @override
  String? get searchableEmbeddingColumn => 'embedding';

  @override
  Object? toSearchableEmbedding() => getAttr<String>('body');
}

/// One dimension per topic word, so distances are known in advance.
Future<List<List<double>>> embed(List<String> texts) async => [
  for (final text in texts)
    [
      for (final word in const ['laravel', 'dart', 'food'])
        text.toLowerCase().contains(word) ? 1.0 : 0.0,
    ],
];

Application boot(String url, {required bool vector}) {
  final uri = Uri.parse(url);
  final user = uri.userInfo.split(':');
  final base = Directory.systemTemp.createTempSync('daravel_scout');
  addTearDown(() => base.deleteSync(recursive: true));
  return Application.configure(basePath: base.path)
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
}

Future<Application> seed(String url, {required bool vector}) async {
  final app = boot(url, vector: vector);
  await app.boot();
  addTearDown(app.shutdown);
  await app.run(() async {
    if (vector) {
      await Schema.ensureVectorExtensionExists();
    }
    await Schema.dropIfExists('scout_articles');
    await Schema.create('scout_articles', (table) {
      table.id();
      table.string('title');
      table.text('body');
      if (vector) {
        table.vector('embedding', dimensions: 3).nullable();
      }
    });
    await DB.table('scout_articles').insert([
      {'id': 1, 'title': 'One', 'body': 'Laravel routing and laravel queues'},
      {'id': 2, 'title': 'Two', 'body': 'Dart isolates'},
      {'id': 3, 'title': 'Three', 'body': 'Laravel and Dart side by side'},
      {'id': 4, 'title': 'Four', 'body': 'Food for thought'},
    ]);
  });
  return app;
}

void main() {
  final pg = Platform.environment['DARAVEL_TEST_PG'];
  final pgvector = Platform.environment['DARAVEL_TEST_PGVECTOR'];

  group('full text', () {
    test('matches words, ranked by relevance', () async {
      final app = await seed(pg ?? pgvector!, vector: false);
      await app.run(() async {
        final found = await Scout.search(Article.definition, 'laravel').get();
        expect([for (final a in found) a.key], [1, 3]);
      });
    });
  }, skip: pg == null && pgvector == null ? 'needs DARAVEL_TEST_PG' : false);

  group('vectors', () {
    late Application app;

    setUp(() async {
      app = await seed(pgvector!, vector: true);
      Scout.embedder = embed;
      await app.run(() async {
        await Scout.makeSearchable(await Article.definition.query().get());
      });
    });

    tearDown(() => Scout.embedder = null);

    test('semantic: nearest by meaning, above the similarity', () async {
      await app.run(() async {
        final found = await Scout.search(
          Article.definition,
          'laravel',
        ).semantic(0.5).get();
        expect([for (final a in found) a.key], [1, 3]);
      });
    });

    test('hybrid fuses the text and the meaning ranks', () async {
      await app.run(() async {
        final found = await Scout.search(
          Article.definition,
          'dart',
        ).hybrid(minSimilarity: 0.5).get();
        expect([for (final a in found) a.key], [2, 3]);
      });
    });

    test('hybrid(rerank: true) reorders by the returned vectors', () async {
      await app.run(() async {
        final found = await Scout.search(
          Article.definition,
          'dart',
        ).hybrid(minSimilarity: 0.5, rerank: true).get();
        expect([for (final a in found) a.key], [2, 3]);
      });
    });
  }, skip: pgvector == null ? 'needs DARAVEL_TEST_PGVECTOR' : false);
}
