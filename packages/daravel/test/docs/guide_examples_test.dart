// Code samples of the documentation site (docs/guide). Regions marked
// `#region name` are copied into the guides by `dart run tool/docs/generate.dart`,
// so every snippet in the docs compiles and runs (BLUEPRINT_V2 §11.3).
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel/html.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

// #region html-layout
/// The site layout (Blade's `@extends('layouts.app')`): every `@yield` and
/// `@stack` is a parameter, and `body` is the default slot.
HtmlDocument appLayout({
  required String title,
  required List<Object?> body,
  List<Object?> head = const [],
  List<Object?> scripts = const [],
  String? csrfToken,
}) => document(
  title: '$title | Example',
  head: [
    link(rel: 'stylesheet', href: '/css/app.css'),
    ...head,
  ],
  // htmx sends these headers with every request from the page.
  bodyAttributes: {
    if (csrfToken != null)
      'hx-headers': jsonEncode({'X-CSRF-TOKEN': csrfToken}),
  },
  [
    header(classes: 'topbar', [
      a(['Home'], href: '/'),
    ]),
    mainEl(id: 'content', body),
    script(src: '/js/htmx.min.js', defer: true),
    ...scripts,
  ],
);

/// A component with named slots (Blade's `<x-card>` with `$title`, the
/// default slot and `<x-slot:actions>`).
Element card({
  required Object? title,
  required List<Object?> body,
  List<Object?>? actions,
}) => article(classes: 'card', [
  h2(classes: 'card-title', [title]),
  div(classes: 'card-body', body),
  if (actions != null) footer(classes: 'card-actions', actions),
]);
// #endregion html-layout

// #region htmx
Element postRow(Post post) => tr(id: 'post-${post.id}', [
  td([post.title]),
  td([
    if (post.published)
      'Published'
    else
      button(
        ['Publish'],
        attributes: {
          'hx-post': '/posts/${post.id}/publish',
          'hx-target': 'closest tr',
          'hx-swap': 'outerHTML',
        },
      ),
  ]),
]);

void webRoutes(Router router) {
  router.get('/posts', (request) async {
    final rows = tbody(id: 'posts', [
      for (final post in await Post.query().get()) postRow(post),
    ]);
    // htmx asks for the rows only; a browser gets the whole page.
    if (request.isHtmx) {
      return rows;
    }
    return appLayout(
      title: 'Posts',
      body: [
        card(
          title: 'Posts',
          body: [
            table([rows]),
          ],
        ),
      ],
    );
  });

  // The answer is the fragment htmx swaps in: the updated row.
  router.post('/posts/{id}/publish', (request) async {
    final post = await Post.query().findOrFail(request.param<int>('id'));
    await post.update({'published': true});
    return postRow(post);
  });

  // `HX-Redirect` for htmx (which would swap a followed 302 into the
  // target), an ordinary 303 for a plain form.
  router.post('/posts/clear', (request) async {
    await Post.query().delete();
    return htmxRedirect(request, '/posts', status: 303);
  });
}
// #endregion htmx

// #region model
final class Post extends Model {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    fillable: ['title', 'body', 'published'],
    casts: {'published': Cast.boolean},
    scopes: {'published': (query, args) => query.where('published', true)},
  );

  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;

  static ModelQuery<Post> query() => definition.query();

  int get id => getAttr('id');
  String get title => getAttr('title');
  bool get published => getAttr('published');
}
// #endregion model

// #region migration
final class CreatePostsTable extends Migration {
  const CreatePostsTable();

  @override
  String get name => '2026_01_01_000000_create_posts_table';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('posts', (table) {
    table.id();
    table.string('title');
    table.text('body').nullable();
    table.boolean('published').defaultTo(false);
    table.timestamps();
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('posts');
}
// #endregion migration

// #region form-request
final class StorePostRequest extends FormRequest {
  const StorePostRequest();

  @override
  Map<String, Object> rules(Request request) => {
    'title': 'required|string|max:120',
    'body': 'nullable|string',
    'published': [Rules.sometimes(), Rules.boolean()],
  };
}
// #endregion form-request

// #region resource
final class PostResource extends JsonResource<Post> {
  PostResource(super.resource);

  /// Documents the item for `dartisan openapi:generate` (`.returns(...)`).
  static const Map<String, Object?> schema = {
    'type': 'object',
    'properties': {
      'id': {'type': 'integer'},
      'title': {'type': 'string'},
      'published': {'type': 'boolean'},
    },
  };

  @override
  Map<String, Object?> toArray(Request? request) => {
    'id': resource.id,
    'title': resource.title,
    'published': resource.published,
  };
}
// #endregion resource

// #region job
final class PublishPost extends Job {
  const PublishPost(this.postId);

  final int postId;

  @override
  String get jobName => 'publish-post';

  @override
  Map<String, Object?> toJson() => {'post_id': postId};

  @override
  Future<void> handle(JobContext ctx) async {
    final post = await Post.query().findOrFail(postId);
    await post.update({'published': true});
  }
}
// #endregion job

final class User extends Model with AuthenticatableModel {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;
}

final class PostPublished {
  const PostPublished(this.postId);
  final int postId;
}

// #region routing
void apiRoutes(Router router) {
  router
      .get('/posts', (request) async {
        final page = await Post.query().scope('published').latest().paginate();
        return JsonResource.collection(page, PostResource.new);
      })
      .name('posts.index');

  router
      .get('/posts/{id}', (request) async {
        final post = await Post.query().findOrFail(request.param<int>('id'));
        return PostResource(post);
      })
      .name('posts.show')
      .whereNumber('id');

  router.group((router) {
    router
        .post('/posts', (request) async {
          final data = request.validated();
          final post = await Post.query().create(data.toMap());
          return PostResource(post).withStatus(201);
        })
        .name('posts.store')
        .validates(const StorePostRequest())
        .returns(PostResource.schema, name: 'Post');
  }, middleware: const ['auth', 'throttle:writes']);
}
// #endregion routing

Application createApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withMigrations(const [
          CreatePostsTable(),
          CreatePersonalAccessTokensTable(),
        ])
        .withJobs([
          JobDefinition(
            'publish-post',
            (json) => PublishPost(json['post_id']! as int),
          ),
        ])
        .withAuth(
          (auth) => auth.token<User>(
            'token',
            ModelUserProvider<User>(User.definition),
          ),
        )
        .withRateLimits((limiter) {
          // #region rate-limit
          limiter.define(
            'writes',
            (request) => Limit.perMinute(30).by(request.ip),
          );
          // #endregion rate-limit
        })
        .withRouting(api: apiRoutes, apiPrefix: '/api', web: webRoutes)
        .create();

void main() {
  late Application app;
  late TestClient client;

  setUp(() async {
    app = createApp();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
    client = TestClient(app);
  });
  tearDown(() => app.shutdown());

  test('query builder and Eloquent', () async {
    await app.run(() async {
      // #region query
      await Post.query().create({'title': 'Hello', 'published': true});
      await DB.table('posts').insert({'title': 'Draft'});

      final published = await Post.query()
          .where('published', true)
          .orderByDesc('id')
          .get();
      final titles = await DB.table('posts').orderBy('id').pluck('title');
      final count = await Post.query().scope('published').count();

      await DB.transaction(() async {
        final post = await Post.query().findOrFail(1);
        await post.update({'title': 'Hello, Daravel'});
      });
      // #endregion query
      expect(published, hasLength(1));
      expect(titles, ['Hello', 'Draft']);
      expect(count, 1);
    });
  });

  test('cache, events and queue', () async {
    await app.run(() async {
      final events = Event.fake();
      final jobs = Queue.fake();
      // #region cache-events-queue
      final total = await Cache.remember(
        'posts.count',
        const Duration(minutes: 5),
        () => Post.query().count(),
      );

      await Event.dispatch(const PostPublished(1));
      await Queue.dispatch(const PublishPost(1)).onQueue('posts');
      // #endregion cache-events-queue
      expect(total, 0);
      events.assertDispatched<PostPublished>();
      jobs.assertPushedOn<PublishPost>('posts');
    });
  });

  test('strings, helpers and collections', () async {
    // #region support
    Str.slug('Laravel & Dart: Hello!'); // laravel-dart-hello
    Str.snake('emailVerifiedAt'); // email_verified_at
    Str.plural('category'); // categories
    Str.limit('The quick brown fox', 9); // The quick...
    Str.mask('ana@example.com', '*', 3); // ana************

    final rows = [
      {'id': 1, 'role': 'admin', 'total': 10},
      {'id': 2, 'role': 'editor', 'total': 5},
      {'id': 3, 'role': 'admin', 'total': 7},
    ];
    rows.pluck('id'); // [1, 2, 3]
    rows.groupBy((row) => row['role']); // {admin: [...], editor: [...]}
    rows.sumBy((row) => row['total']! as int); // 22
    rows.sortByDesc((row) => row['total']! as int).pluck('id'); // [1, 3, 2]

    final rate = await retry(3, (attempt) async => fetchRate(attempt));
    final cached = await rescue(() async => fetchRate(0), fallback: 1.0);
    blank('  '); // true
    dataGet({
      'user': {'name': 'Ana'},
    }, 'user.name'); // Ana
    // #endregion support
    expect(Str.slug('Laravel & Dart: Hello!'), 'laravel-dart-hello');
    expect(Str.mask('ana@example.com', '*', 3), 'ana************');
    expect(rate, 15600.0);
    expect(cached, 1.0);
  });

  test('HTML layout, slots and htmx fragments', () async {
    final post = await app.run(
      () => Post.query().create({'title': 'Hello <b>', 'published': false}),
    );
    const htmx = {'HX-Request': 'true'};

    final page = (await client.get('/posts')).assertOk();
    page
        .assertSee('<!doctype html>')
        .assertSee('<title>Posts | Example</title>')
        .assertSee('<article class="card"><h2 class="card-title">Posts</h2>')
        .assertSee('<td>Hello &lt;b&gt;</td>')
        .assertSee('<script src="/js/htmx.min.js" defer></script>');

    (await client.get(
      '/posts',
      headers: htmx,
    )).assertOk().assertHeader('content-type', 'text/html; charset=utf-8');
    final fragment = (await client.get('/posts', headers: htmx)).body;
    expect(fragment, startsWith('<tbody id="posts"><tr id="post-${post.id}">'));

    (await client.post(
      '/posts/${post.id}/publish',
      headers: htmx,
    )).assertOk().assertSee('<td>Published</td>');

    (await client.post(
      '/posts/clear',
      headers: htmx,
    )).assertOk().assertHeader('hx-redirect', '/posts');
    (await client.post('/posts/clear')).assertRedirect('/posts');

    final layout = appLayout(
      title: 'Home',
      csrfToken: 'tok',
      body: [
        card(title: 'Hi', body: ['x'], actions: ['y']),
      ],
    ).render();
    expect(layout, contains('<body hx-headers="{&quot;X-CSRF-TOKEN&quot;:'));
    expect(layout, contains('<footer class="card-actions">y</footer>'));
  });

  test('HTTP feature test', () async {
    await app.run(
      () => Post.query().create({'title': 'Hello', 'published': true}),
    );
    // #region testing
    (await client.get('/api/posts'))
        .assertOk()
        .assertJsonPath('data.0.title', 'Hello')
        .assertJsonPath('meta.total', 1);

    (await client.post(
      '/api/posts',
      json: {'title': 'x'},
    )).assertUnauthorized().assertJsonPath('message', 'Unauthenticated.');

    (await client.get('/api/posts/99')).assertNotFound();
    // #endregion testing
  });
}

/// Fails twice, then answers (the `retry` example).
double fetchRate(int attempt) {
  if (attempt > 0 && attempt < 3) {
    throw StateError('timeout');
  }
  if (attempt == 0) {
    throw StateError('offline');
  }
  return 15600.0;
}
