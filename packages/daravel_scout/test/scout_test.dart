import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_scout/daravel_scout.dart';
import 'package:test/test.dart';

final class Post extends Model with Searchable {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    timestamps: false,
    casts: const {'embedding': Cast.vector},
  );

  @override
  ModelDefinition<Post> get modelDefinition => definition;

  @override
  Map<String, Object?> toSearchableArray() => const {
    'id': null,
    'title': null,
    'body': null,
  };

  @override
  List<String> get searchUsingPrefix => const ['title'];

  @override
  String? get searchableEmbeddingColumn => 'embedding';

  @override
  Object? toSearchableEmbedding() => getAttr<String>('body');
}

final class Plain extends Model {
  static final ModelDefinition<Plain> definition = ModelDefinition<Plain>(
    table: 'posts',
    factory: Plain.new,
    timestamps: false,
  );

  @override
  ModelDefinition<Plain> get modelDefinition => definition;
}

final class FullText extends Model with Searchable {
  static final ModelDefinition<FullText> definition = ModelDefinition<FullText>(
    table: 'posts',
    factory: FullText.new,
    timestamps: false,
  );

  @override
  ModelDefinition<FullText> get modelDefinition => definition;

  @override
  Map<String, Object?> toSearchableArray() => const {'body': null};

  @override
  List<String> get searchUsingFullText => const ['body'];
}

void main() {
  late Application app;

  setUp(() async {
    final base = Directory.systemTemp.createTempSync('daravel_scout');
    addTearDown(() => base.deleteSync(recursive: true));
    app = Application.configure(basePath: base.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    await app.run(() async {
      await DB.statement(
        'CREATE TABLE posts (id INTEGER PRIMARY KEY, title TEXT, body TEXT, '
        'category TEXT, embedding TEXT)',
      );
      await DB.table('posts').insert([
        {'id': 1, 'title': 'Laravel tips', 'body': 'routes', 'category': 'a'},
        {
          'id': 2,
          'title': 'Dart tips',
          'body': 'about laravel',
          'category': 'b',
        },
        {'id': 3, 'title': 'Cooking', 'body': 'rice', 'category': 'a'},
        {'id': 12, 'title': 'Twelve', 'body': 'x', 'category': 'a'},
      ]);
    });
    Scout.embedder = null;
  });

  Future<List<Object?>> ids(ScoutBuilder<Post> search) =>
      app.run(() async => [for (final p in await search.get()) p.key]);

  test('LIKE on every column, newest key first', () async {
    expect(await ids(Scout.search(Post.definition, 'laravel')), [2, 1]);
  });

  test('a prefix column matches only at the start', () async {
    expect(await ids(Scout.search(Post.definition, 'tips')), isEmpty);
    expect(await ids(Scout.search(Post.definition, 'Dart')), [2]);
  });

  test('a numeric query also finds the key', () async {
    expect(await ids(Scout.search(Post.definition, '12')), [12]);
  });

  test('an empty query lists everything', () async {
    expect(await ids(Scout.search(Post.definition)), [12, 3, 2, 1]);
  });

  test('where, whereIn, whereNotIn, take and orderBy', () async {
    expect(
      await ids(Scout.search(Post.definition).where('category', 'a').take(2)),
      [12, 3],
    );
    expect(await ids(Scout.search(Post.definition).whereIn('id', [1, 3])), [
      3,
      1,
    ]);
    expect(await ids(Scout.search(Post.definition).whereNotIn('id', [12, 3])), [
      2,
      1,
    ]);
    expect(await ids(Scout.search(Post.definition).orderBy('title').take(2)), [
      3,
      2,
    ]);
  });

  test('constrain adds to the database query', () async {
    expect(
      await ids(
        Scout.search(
          Post.definition,
          'tips',
        ).constrain((q) => q.where('category', 'b')),
      ),
      isEmpty,
    );
  });

  test('first, keys and paginate', () async {
    await app.run(() async {
      expect((await Scout.search(Post.definition, 'laravel').first())!.key, 2);
      expect(await Scout.search(Post.definition, 'laravel').keys(), [2, 1]);
      final page = await Scout.search(Post.definition).paginate(perPage: 3);
      expect(page.total, 4);
      expect([for (final p in page.items) p.key], [12, 3, 2]);
    });
  });

  test('full text needs a database that has it', () async {
    await app.run(() async {
      await expectLater(
        Scout.search(FullText.definition, 'rice').get(),
        throwsUnsupportedError,
      );
    });
  });

  test('semantic and hybrid ask for what they need', () async {
    expect(
      () => Scout.search(Post.definition).semantic(),
      throwsA(isA<ScoutException>()),
    );
    expect(
      () => Scout.search(Post.definition, 'x').hybrid(textWeight: 0),
      throwsA(isA<ScoutException>()),
    );
    await app.run(() async {
      await expectLater(
        Scout.search(Post.definition, 'x').semantic().get(),
        throwsUnsupportedError,
        reason: 'SQLite has no vector distance',
      );
    });
  });

  test('a model without Searchable is refused', () {
    expect(
      () => Scout.search(Plain.definition, 'x').get(),
      throwsArgumentError,
    );
  });

  test('fuse ranks by weighted reciprocal rank, ties by key', () {
    Post post(int id) => Post()..forceFill({'id': id});
    final a = post(1), b = post(2), c = post(3);
    expect(
      [
        for (final p in Scout.fuse([a, b], [b, c])) p.key,
      ],
      [2, 1, 3],
      reason: 'b is in both; a and c tie, and 1 sorts before 3',
    );
    expect(
      [
        for (final p in Scout.fuse(
          [a, b],
          [b, c],
          textWeight: 1,
          semanticWeight: 3,
        ))
          p.key,
      ],
      [2, 3, 1],
    );
  });

  test('makeSearchable writes the vectors', () async {
    Scout.embedder = (texts) async => [
      for (final t in texts) [t.length.toDouble(), 1.0],
    ];
    await app.run(() async {
      final posts = await Post.definition.query().get();
      await Scout.makeSearchable(posts);
      final row = await DB.table('posts').where('id', 3).first();
      expect(row!['embedding'], '[4.0,1.0]');
    });
  });
}
