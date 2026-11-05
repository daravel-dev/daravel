@Tags(['integration'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
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

  // Natural language mode leaves out words in half the rows or more, which
  // a table this small always has.
  @override
  Map<String, String> get fullTextOptions => const {'mode': 'boolean'};

  @override
  String? get searchableEmbeddingColumn => 'embedding';

  @override
  Object? toSearchableEmbedding() => getAttr<String>('body');
}

Future<List<List<double>>> embed(List<String> texts) async => [
  for (final text in texts)
    [
      for (final word in const ['laravel', 'dart', 'food'])
        text.toLowerCase().contains(word) ? 1.0 : 0.0,
    ],
];

/// MariaDB 11.7 or newer, e.g.
/// `DARAVEL_TEST_MARIADB_VECTOR=mysql://daravel:secret@127.0.0.1:3306/daravel_test`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_MARIADB_VECTOR'];

  group('MariaDB', () {
    late Application app;

    setUp(() async {
      final uri = Uri.parse(url!);
      final user = uri.userInfo.split(':');
      final base = Directory.systemTemp.createTempSync('daravel_scout');
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
      Scout.embedder = embed;
      addTearDown(() => Scout.embedder = null);
      await app.run(() async {
        await Schema.dropIfExists('scout_articles');
        await Schema.create('scout_articles', (table) {
          table.id();
          table.string('title');
          table.text('body');
          table.vector('embedding', dimensions: 3).nullable();
        });
        await DB.statement(
          'CREATE FULLTEXT INDEX scout_articles_body ON scout_articles (body)',
        );
        await DB.table('scout_articles').insert([
          {'id': 1, 'title': 'One', 'body': 'Laravel routing and queues'},
          {'id': 2, 'title': 'Two', 'body': 'Dart isolates'},
          {'id': 3, 'title': 'Three', 'body': 'Laravel and Dart side by side'},
          {'id': 4, 'title': 'Four', 'body': 'Food for thought'},
        ]);
        await Scout.makeSearchable(await Article.definition.query().get());
      });
    });

    test('full text with MATCH', () async {
      await app.run(() async {
        final found = await Scout.search(Article.definition, 'laravel').get();
        expect({for (final a in found) a.key}, {1, 3});
      });
    });

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
        expect({for (final a in found) a.key}, {2, 3});
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
  }, skip: url == null ? 'needs DARAVEL_TEST_MARIADB_VECTOR' : false);
}
