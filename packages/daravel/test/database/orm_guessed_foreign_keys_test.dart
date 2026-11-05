import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `BelongsTo`, `HasMany` and `HasOne` guess their foreign key as
/// Laravel's `belongsTo` / `hasMany` / `hasOne` do.
final class Author extends Model {
  static final ModelDefinition<Author> definition = ModelDefinition<Author>(
    table: 'authors',
    factory: Author.new,
    timestamps: false,
    relations: {
      'blogPosts': () => HasMany<BlogPost>(() => BlogPost.definition),
      'latestPost': () => HasOne<BlogPost>(() => BlogPost.definition),
    },
  );
  @override
  ModelDefinition<Author> get modelDefinition => definition;
}

final class BlogPost extends Model {
  static final ModelDefinition<BlogPost> definition = ModelDefinition<BlogPost>(
    table: 'blog_posts',
    factory: BlogPost.new,
    timestamps: false,
    relations: {
      'author': () => BelongsTo<Author>(() => Author.definition),
      'coAuthor': () => BelongsTo<Author>(() => Author.definition),
      'editor': () =>
          BelongsTo<Author>(() => Author.definition, foreignKey: 'edited_by'),
      'comments': () => HasMany<Comment>(() => Comment.definition),
    },
  );
  @override
  ModelDefinition<BlogPost> get modelDefinition => definition;
}

/// A model whose Laravel class is not `App\Models\Comment`.
final class Comment extends Model {
  static final ModelDefinition<Comment> definition = ModelDefinition<Comment>(
    table: 'comments',
    factory: Comment.new,
    timestamps: false,
    morphClass: r'App\Domain\PostComment',
    relations: {'replies': () => HasMany<Comment>(() => Comment.definition)},
  );
  @override
  ModelDefinition<Comment> get modelDefinition => definition;
}

void main() {
  test('the keys Laravel would guess', () {
    String key(ModelDefinition<Model> def, String name) =>
        switch (def.relation(name)) {
          final BelongsTo<Model> r => r.foreignKey,
          final HasMany<Model> r => r.foreignKey,
          _ => throw StateError(name),
        };
    expect(key(Author.definition, 'blogPosts'), 'author_id');
    expect(key(Author.definition, 'latestPost'), 'author_id');
    expect(key(BlogPost.definition, 'author'), 'author_id');
    expect(key(BlogPost.definition, 'coAuthor'), 'co_author_id');
    expect(key(BlogPost.definition, 'editor'), 'edited_by');
    expect(key(BlogPost.definition, 'comments'), 'blog_post_id');
    expect(key(Comment.definition, 'replies'), 'post_comment_id');
  });

  test('a relation outside a definition needs its key', () {
    expect(
      () => BelongsTo<Author>(() => Author.definition).foreignKey,
      throwsStateError,
    );
    expect(
      () => HasMany<BlogPost>(() => BlogPost.definition).foreignKey,
      throwsStateError,
    );
  });

  group('queries with guessed keys', () {
    late Directory base;
    late Application app;

    setUp(() async {
      base = Directory.systemTemp.createTempSync('daravel_guessed_keys');
      app = Application.configure(basePath: base.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .create();
      await app.boot();
      await app.run(() async {
        for (final sql in const [
          'CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT)',
          'CREATE TABLE blog_posts (id INTEGER PRIMARY KEY, author_id INTEGER, '
              'co_author_id INTEGER, edited_by INTEGER, title TEXT)',
          "INSERT INTO authors (id, name) VALUES (1, 'Ana'), (2, 'Budi')",
          'INSERT INTO blog_posts (id, author_id, co_author_id, title) '
              "VALUES (1, 1, 2, 'One'), (2, 1, NULL, 'Two')",
        ]) {
          await DB.statement(sql);
        }
      });
    });

    tearDown(() async {
      await app.shutdown();
      base.deleteSync(recursive: true);
    });

    test('eager loads and whereHas use them', () {
      return app.run(() async {
        final authors = await Author.definition
            .query()
            .with_(['blogPosts'])
            .orderBy('id')
            .get();
        expect(
          (authors.first.relations['blogPosts']! as List<Model>).length,
          2,
        );
        final posts = await BlogPost.definition
            .query()
            .with_(['author', 'coAuthor'])
            .orderBy('id')
            .get();
        expect(
          (posts.first.relations['coAuthor']! as Model).attributes['name'],
          'Budi',
        );
        expect(posts.last.relations['coAuthor'], isNull);
        final withCo = await BlogPost.definition
            .query()
            .whereHas('coAuthor')
            .get();
        expect(withCo.map((p) => p.key), [1]);
      });
    });
  });
}
