// Code samples of the documentation site (docs/guide). Regions marked
// `#region name` are copied into the guides by `dart run tool/docs/generate.dart`,
// so every snippet in the docs compiles and runs (BLUEPRINT_V2 §11.3).
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

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
          final data = await FormRequest.run(const StorePostRequest(), request);
          final post = await Post.query().create(data.toMap());
          return PostResource(post).withStatus(201);
        })
        .name('posts.store');
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
        .withRouting(api: apiRoutes, apiPrefix: '/api')
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
