import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `with_('relation:column,column')` (Laravel's colon syntax), and the keys
/// Daravel adds when a selection leaves them out.
final class Author extends Model {
  static final ModelDefinition<Author> definition = ModelDefinition<Author>(
    table: 'users',
    factory: Author.new,
    guarded: [],
    timestamps: false,
    relations: {
      'posts': () =>
          HasMany<Article>(() => Article.definition, foreignKey: 'user_id'),
      'roles': () => BelongsToMany<Role>(
        () => Role.definition,
        pivotTable: 'role_user',
        foreignPivotKey: 'user_id',
        relatedPivotKey: 'role_id',
        withPivot: ['granted_by'],
      ),
      'comments': () => HasManyThrough<Remark>(
        () => Remark.definition,
        through: () => Article.definition,
        firstKey: 'user_id',
        secondKey: 'post_id',
      ),
    },
  );

  @override
  ModelDefinition<Author> get modelDefinition => Author.definition;
}

final class Article extends Model {
  static final ModelDefinition<Article> definition = ModelDefinition<Article>(
    table: 'posts',
    factory: Article.new,
    guarded: [],
    timestamps: false,
    relations: {
      'author': () =>
          BelongsTo<Author>(() => Author.definition, foreignKey: 'user_id'),
      'comments': () =>
          HasMany<Remark>(() => Remark.definition, foreignKey: 'post_id'),
    },
  );

  @override
  ModelDefinition<Article> get modelDefinition => Article.definition;
}

final class Remark extends Model {
  static final ModelDefinition<Remark> definition = ModelDefinition<Remark>(
    table: 'comments',
    factory: Remark.new,
    guarded: [],
    timestamps: false,
    relations: {
      'author': () =>
          BelongsTo<Author>(() => Author.definition, foreignKey: 'author_id'),
    },
  );

  @override
  ModelDefinition<Remark> get modelDefinition => Remark.definition;
}

final class Role extends Model {
  static final ModelDefinition<Role> definition = ModelDefinition<Role>(
    table: 'roles',
    factory: Role.new,
    guarded: [],
    timestamps: false,
  );

  @override
  ModelDefinition<Role> get modelDefinition => Role.definition;
}

final class Image extends Model {
  static final ModelDefinition<Image> definition = ModelDefinition<Image>(
    table: 'images',
    factory: Image.new,
    guarded: [],
    timestamps: false,
    relations: {
      'imageable': () => MorphTo(types: [() => Article.definition]),
    },
  );

  @override
  ModelDefinition<Image> get modelDefinition => Image.definition;
}

void main() {
  late Application app;
  final sql = <String>[];

  setUp(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .create();
    await app.boot();
    await app.run(() async {
      await Schema.create('users', (t) {
        t.id();
        t.string('name');
        t.string('email');
        t.string('password');
      });
      await Schema.create('posts', (t) {
        t.id();
        t.foreignId('user_id');
        t.string('title');
        t.text('body');
      });
      await Schema.create('comments', (t) {
        t.id();
        t.foreignId('post_id');
        t.foreignId('author_id');
        t.string('body');
        t.string('secret');
      });
      await Schema.create('roles', (t) {
        t.id();
        t.string('name');
        t.string('guard');
      });
      await Schema.create('role_user', (t) {
        t.foreignId('user_id');
        t.foreignId('role_id');
        t.string('granted_by');
      });
      await Schema.create('images', (t) {
        t.id();
        t.string('imageable_type');
        t.unsignedBigInteger('imageable_id');
        t.string('path');
      });
      await DB.table('users').insert([
        {'id': 1, 'name': 'Ana', 'email': 'ana@x.io', 'password': 'hash'},
        {'id': 2, 'name': 'Bo', 'email': 'bo@x.io', 'password': 'hash'},
      ]);
      await DB.table('posts').insert([
        {'id': 10, 'user_id': 1, 'title': 'A', 'body': 'long A'},
        {'id': 11, 'user_id': 1, 'title': 'B', 'body': 'long B'},
        {'id': 12, 'user_id': 2, 'title': 'C', 'body': 'long C'},
      ]);
      await DB.table('comments').insert([
        {'id': 100, 'post_id': 10, 'author_id': 2, 'body': 'x', 'secret': 's'},
        {'id': 101, 'post_id': 12, 'author_id': 1, 'body': 'y', 'secret': 's'},
      ]);
      await DB.table('roles').insert([
        {'id': 1, 'name': 'admin', 'guard': 'web'},
        {'id': 2, 'name': 'editor', 'guard': 'web'},
      ]);
      await DB.table('role_user').insert([
        {'user_id': 1, 'role_id': 1, 'granted_by': 'root'},
        {'user_id': 1, 'role_id': 2, 'granted_by': 'root'},
      ]);
      await DB.table('images').insert([
        {
          'id': 1,
          'imageable_type': Article.definition.morphClass,
          'imageable_id': 12,
          'path': 'c.png',
        },
      ]);
      sql.clear();
      DB.listen((event) => sql.add(event.sql));
    });
  });
  tearDown(() => app.shutdown());

  Set<String> columns(Model model) => model.attributes.keys.toSet();

  /// The SELECT that read [table].
  String readOf(String table) =>
      sql.lastWhere((s) => s.contains('FROM "$table"'));

  test('one relation, only its columns', () async {
    await app.run(() async {
      final posts = await Article.definition
          .query()
          .with_('author:id,name')
          .get();
      final author = posts.first.relations['author']! as Model;
      expect(columns(author), {'id', 'name'});
      expect(readOf('users'), startsWith('SELECT "id", "name" FROM "users"'));
    });
  });

  test('several, as a list; whitespace is trimmed', () async {
    await app.run(() async {
      final users = await Author.definition.query().with_([
        ' posts : id , user_id , title ',
        'roles:name',
      ]).get();
      final posts = users.first.relations['posts']! as List<Model>;
      expect(posts.map(columns), everyElement({'id', 'user_id', 'title'}));
      final roles = users.first.relations['roles']! as List<Model>;
      expect(roles.map((r) => r.attributes['name']), ['admin', 'editor']);
      expect(roles.first.attributes, isNot(contains('guard')));
      expect(roles.first.pivot?['granted_by'], 'root');
    });
  });

  test('the matching key is added when left out', () async {
    await app.run(() async {
      // BelongsTo: users.id.
      final posts = await Article.definition.query().with_('author:name').get();
      expect(
        posts.map((p) => (p.relations['author']! as Model).attributes['name']),
        ['Ana', 'Ana', 'Bo'],
      );
      expect(columns(posts.first.relations['author']! as Model), {
        'name',
        'id',
      });
      // HasMany: posts.user_id.
      final users = await Author.definition.query().with_('posts:title').get();
      expect(
        (users.first.relations['posts']! as List<Model>).map(
          (p) => p.attributes['title'],
        ),
        ['A', 'B'],
      );
      expect(columns((users.first.relations['posts']! as List<Model>).first), {
        'title',
        'user_id',
      });
    });
  });

  test(
    'nested: each level selects its own, and keeps what the next reads',
    () async {
      await app.run(() async {
        final users = await Author.definition.query().with_([
          'posts:title',
          'posts.comments:body',
          'posts.comments.author:name',
        ]).get();
        final posts = users.first.relations['posts']! as List<Model>;
        // posts.id kept for comments, comments.author_id for their author.
        expect(columns(posts.first), {'title', 'user_id', 'id'});
        final comments = posts.first.relations['comments']! as List<Model>;
        expect(columns(comments.single), {'body', 'post_id', 'author_id'});
        expect((comments.single.relations['author']! as Model).attributes, {
          'name': 'Bo',
          'id': 2,
        });
      });
    },
  );

  test('a map key with columns, next to its constraint', () async {
    await app.run(() async {
      final users = await Author.definition.query().with_({
        'posts:id,title': (ModelQuery<Model> q) => q.where('title', 'B'),
      }).get();
      final posts = users.first.relations['posts']! as List<Model>;
      expect(posts.map((p) => p.attributes['title']), ['B']);
    });
  });

  test('through relations stay unambiguous and grouped', () async {
    await app.run(() async {
      final users = await Author.definition
          .query()
          .with_('comments:body')
          .get();
      expect(
        (users.first.relations['comments']! as List<Model>).map(
          (c) => c.attributes['body'],
        ),
        ['x'],
      );
      expect(
        (users.last.relations['comments']! as List<Model>).map(
          (c) => c.attributes['body'],
        ),
        ['y'],
      );
      expect(readOf('comments'), contains('"comments"."body"'));
    });
  });

  test('morphTo keeps each target key', () async {
    await app.run(() async {
      final images = await Image.definition
          .query()
          .with_('imageable:title')
          .get();
      final post = images.single.relations['imageable']! as Model;
      expect(post.attributes, {'title': 'C', 'id': 12});
    });
  });

  test("a root selection keeps its relations' keys", () async {
    await app.run(() async {
      final posts = await Article.definition
          .query()
          .select(['title'])
          .with_('author:name')
          .get();
      expect(columns(posts.first), {'title', 'user_id'});
      expect(
        (posts.first.relations['author']! as Model).attributes['name'],
        'Ana',
      );
      // Without relations, nothing is added.
      final plain = await Article.definition.query().select(['title']).get();
      expect(columns(plain.first), {'title'});
    });
  });

  test('load() on loaded models takes the syntax too', () async {
    await app.run(() async {
      final posts = await Article.definition.query().get();
      await posts.load('author:name');
      expect((posts.first.relations['author']! as Model).attributes, {
        'name': 'Ana',
        'id': 1,
      });
    });
  });
}
