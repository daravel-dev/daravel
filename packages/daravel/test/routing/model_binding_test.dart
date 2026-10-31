import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

final class Author extends Model {
  static final ModelDefinition<Author> definition = ModelDefinition<Author>(
    table: 'authors',
    factory: Author.new,
    timestamps: false,
    relations: {
      'posts': () =>
          HasMany<Post>(() => Post.definition, foreignKey: 'author_id'),
    },
  );
  @override
  ModelDefinition<Author> get modelDefinition => definition;
}

final class Post extends Model {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    timestamps: false,
    softDeletes: true,
    relations: {
      'labels': () => BelongsToMany<Label>(
        () => Label.definition,
        pivotTable: 'label_post',
        foreignPivotKey: 'post_id',
        relatedPivotKey: 'label_id',
      ),
    },
  );
  @override
  ModelDefinition<Post> get modelDefinition => definition;
}

final class Label extends Model {
  static final ModelDefinition<Label> definition = ModelDefinition<Label>(
    table: 'labels',
    factory: Label.new,
    timestamps: false,
  );
  @override
  ModelDefinition<Label> get modelDefinition => definition;
}

void main() {
  late Directory base;
  late Application app;
  late TestClient client;

  Map<String, Object?> show(Request request) => {
    'id': request.binding<Post>('post').getAttr<int>('id'),
  };

  setUp(() async {
    base = Directory.systemTemp.createTempSync('daravel_binding');
    app = Application.configure(basePath: base.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          web: (router) {
            router
              ..bindModel('author', Author.definition)
              ..bindModel('post', Post.definition)
              ..bindModel('label', Label.definition);
            router.get('/plain/{id}', (r) => {'id': r.routeParams['id']});
            router.get('/posts/{post}', show);
            router.get('/slug/{post:slug}', show);
            router.get('/trashed/{post}', show).withTrashed();
            router
                .get('/gone/{post}', show)
                .missing((_) => Response.redirect('/elsewhere'));
            router.get('/open/{author}/{post}', show);
            router.get('/scoped/{author}/{post}', show).scopeBindings();
            router.get('/implied/{author}/{post:slug}', show);
            router
                .get('/unscoped/{author}/{post:slug}', show)
                .withoutScopedBindings();
            router.group((r) {
              r.get('/in-group/{author}/{post}', show);
            }, scopeBindings: true);
            router
                .get(
                  '/labels/{post}/{label}',
                  (r) => {'id': r.binding<Label>('label').getAttr<int>('id')},
                )
                .scopeBindings();
            router.get('/unrelated/{post}/{author}', show).scopeBindings();
          },
        )
        .create();
    await app.boot();
    await app.run(() async {
      for (final sql in const [
        'CREATE TABLE authors (id INTEGER PRIMARY KEY)',
        'CREATE TABLE posts (id INTEGER PRIMARY KEY, author_id INTEGER, '
            'slug TEXT, deleted_at TEXT)',
        'CREATE TABLE labels (id INTEGER PRIMARY KEY)',
        'CREATE TABLE label_post (id INTEGER PRIMARY KEY, post_id INTEGER, '
            'label_id INTEGER)',
      ]) {
        await DB.statement(sql);
      }
      await DB.table('authors').insert([
        {'id': 1},
        {'id': 2},
      ]);
      await DB.table('posts').insert([
        {'id': 10, 'author_id': 1, 'slug': 'mine', 'deleted_at': null},
        {'id': 20, 'author_id': 2, 'slug': 'theirs', 'deleted_at': null},
        {'id': 30, 'author_id': 1, 'slug': 'old', 'deleted_at': '2026'},
      ]);
      await DB.table('labels').insert([
        {'id': 5},
        {'id': 6},
      ]);
      await DB.table('label_post').insert([
        {'id': 6, 'post_id': 10, 'label_id': 5},
      ]);
    });
    client = TestClient(app);
  });

  tearDown(() async {
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  Future<int> status(String uri) async => (await client.get(uri)).status;

  test('a parameter without a binding stays a string', () async {
    final response = await client.get('/plain/42');
    expect(response.jsonMap['id'], '42');
  });

  test('the primary key binds', () async {
    expect((await client.get('/posts/10')).jsonMap['id'], 10);
  });

  test('a missing model answers Laravel\'s 404', () async {
    final response = await client.get(
      '/posts/99',
      headers: {'accept': 'application/json'},
    );
    expect(response.status, 404);
    expect(response.jsonMap['message'], contains('No query results for model'));
  });

  test('a word in an integer key is a 404, not a query error', () async {
    expect(await status('/posts/abc'), 404);
  });

  test('{post:slug} binds by that column', () async {
    expect((await client.get('/slug/mine')).jsonMap['id'], 10);
    expect(await status('/slug/10'), 404);
  });

  test('a soft deleted model needs withTrashed', () async {
    expect(await status('/posts/30'), 404);
    expect((await client.get('/trashed/30')).jsonMap['id'], 30);
  });

  test('missing replaces the 404', () async {
    final response = await client.get('/gone/99');
    expect(response.status, 302);
    expect(response.headers.first('location'), '/elsewhere');
  });

  group('scoping stops access to another owner\'s rows', () {
    test('without it, any post goes', () async {
      expect(await status('/open/1/20'), 200);
    });

    test('scopeBindings', () async {
      expect(await status('/scoped/1/10'), 200);
      expect(await status('/scoped/1/20'), 404);
      expect(await status('/scoped/2/20'), 200);
    });

    test('a custom column implies it', () async {
      expect(await status('/implied/1/mine'), 200);
      expect(await status('/implied/1/theirs'), 404);
    });

    test('withoutScopedBindings turns that off', () async {
      expect(await status('/unscoped/1/theirs'), 200);
    });

    test('from a group', () async {
      expect(await status('/in-group/1/20'), 404);
      expect(await status('/in-group/2/20'), 200);
    });

    test('a soft deleted child stays out', () async {
      expect(await status('/scoped/1/30'), 404);
    });

    test('through a pivot that has an id of its own', () async {
      final response = await client.get('/labels/10/5');
      expect(response.status, 200);
      expect(response.jsonMap['id'], 5);
      expect(await status('/labels/10/6'), 404);
    });

    test('no such relation is a clear error', () async {
      final response = await client
          .withoutExceptionHandling()
          .get('/unrelated/10/1')
          .then<Object?>((r) => r, onError: (Object e) => e);
      expect('$response', contains('declare the relation in Post'));
    });
  });

  test('OpenAPI shows {post:slug} as a plain parameter', () {
    final router = Router()..get('/x/{post:slug}/{page:num?}', (_) => null);
    router.compile(MiddlewareRegistry());
    final paths =
        buildOpenApi(router.routes, title: 'x', version: '1')['paths']!
            as Map<String, Object?>;
    expect(paths.keys, ['/x/{post}/{page}']);
    final get = (paths.values.single! as Map)['get'] as Map;
    final parameters = get['parameters'] as List<Object?>;
    expect(
      [for (final p in parameters) (p! as Map)['required']],
      [true, false],
    );
  });

  test('a column that is no identifier is refused', () {
    expect(
      () => RouteEntry(
        methods: const ['GET'],
        path: '/x/{post:a b}',
        handler: (_) => null,
      ),
      throwsArgumentError,
    );
  });

  test('url generation fills {post:slug}', () {
    final router = Router()
      ..get('/x/{post:slug}/{page:num?}', (_) => null).name('x');
    router.compile(MiddlewareRegistry());
    expect(router.url('x', params: {'post': 'mine'}), '/x/mine');
    expect(router.url('x', params: {'post': 'mine', 'page': 2}), '/x/mine/2');
  });
}
