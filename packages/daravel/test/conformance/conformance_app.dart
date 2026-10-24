import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';

/// Laravel's default `users` model (`App\Models\User`).
final class User extends Model with AuthenticatableModel {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
    fillable: ['name', 'email', 'password'],
    hidden: ['password', 'remember_token'],
    casts: {'email_verified_at': Cast.dateTime},
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;

  int get id => getAttr('id');
  String get name => getAttr('name');
}

/// A paginated model (`App\Models\Post`).
final class Post extends Model {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    fillable: ['title'],
    timestamps: false,
  );

  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;

  int get id => getAttr('id');
  String get title => getAttr('title');
}

final class PostResource extends JsonResource<Post> {
  PostResource(super.resource);

  @override
  Map<String, Object?> toArray(Request? request) => {
    'id': resource.id,
    'title': resource.title,
  };
}

/// laravel/laravel 12.x `0001_01_01_000000_create_users_table` (users only).
final class CreateUsersTable extends Migration {
  const CreateUsersTable();

  @override
  String get name => '0001_01_01_000000_create_users_table';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('users', (table) {
    table.id();
    table.string('name');
    table.string('email').unique();
    table.timestamp('email_verified_at').nullable();
    table.string('password');
    table.string('remember_token', length: 100).nullable();
    table.timestamps();
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('users');
}

final class CreatePostsTable extends Migration {
  const CreatePostsTable();

  @override
  String get name => '2026_01_01_000000_create_posts_table';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('posts', (table) {
    table.id();
    table.string('title');
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('posts');
}

final class PhotoController implements ResourceController {
  @override
  Object? index(Request request) => 'index';
  @override
  Object? store(Request request) => 'store';
  @override
  Object? show(Request request) => 'show ${request.routeParams['photo']}';
  @override
  Object? update(Request request) => 'update';
  @override
  Object? destroy(Request request) => 'destroy';
}

/// The application every conformance test runs against: the shared Laravel
/// tables, a token guard, a gate, a throttled route and one route per
/// contract under `/api`.
Application conformanceApp({
  Map<String, String> env = const {},
}) => Application.configure(basePath: Directory.systemTemp.path)
    .withEnv(<String, String>{
      'APP_ENV': 'testing',
      'APP_DEBUG': 'false',
      'DB_DATABASE': ':memory:',
      'APP_KEY': 'base64:${'A' * 43}=',
      'HASH_DRIVER': 'bcrypt',
      ...env,
    })
    .withMigrations(const [
      CreateUsersTable(),
      CreatePostsTable(),
      CreateCacheTable(),
      CreateJobsTable(),
      CreatePersonalAccessTokensTable(),
    ])
    .withAuth((auth) {
      auth.token<User>('token', ModelUserProvider<User>(User.definition));
    })
    .withPolicies((gate) => gate.define('never', (user, args) => false))
    .withRateLimits((limiter) {
      limiter.define('one', (_) => Limit.perMinute(1).by('one'));
    })
    .withMiddleware(
      (m) => m.use(const <Middleware>[BodyLimitsMiddleware(json: 512)]),
    )
    .withRouting(
      apiPrefix: '/api',
      api: (r) {
        r.get('/boom', (_) => throw StateError('secret detail'));
        r.get('/abort/{code}', (req) => abort(req.param<int>('code')));
        r.get('/teapot', (_) => abort(418, "I'm a teapot"));
        r.get(
          '/users/{id}',
          (req) => User.definition.query().findOrFail(req.param<int>('id')),
        );
        r.get(
          '/users-first',
          (_) => User.definition.query().where('id', 0).firstOrFail(),
        );
        r.post('/echo', (req) async => await req.all());
        r.post(
          '/validate',
          (req) async => (await req.validate({
            'name': 'required|string|max:5',
            'email': 'required|email',
            'password': 'required|min:8|confirmed',
            'age': 'nullable|integer',
            'nickname': 'sometimes|required|string',
          })).toMap(),
        );
        r.get('/me', (req) async => Auth.user()).middleware(const ['auth']);
        r.get('/forbidden', (_) async {
          await Gate.authorize('never');
          return 'unreachable';
        });
        r.get('/throttled', (_) => 'ok').middleware(const ['throttle:one']);
        r.get('/date', (_) => {'at': DateTime.utc(2026, 1, 2, 3, 4, 5, 6, 7)});
        r.get(
          '/posts',
          (_) => Post.definition.query().orderBy('id').paginate(perPage: 2),
        );
        r.get(
          '/posts/simple',
          (_) =>
              Post.definition.query().orderBy('id').simplePaginate(perPage: 2),
        );
        r.get(
          '/posts/cursor',
          (_) =>
              Post.definition.query().orderBy('id').cursorPaginate(perPage: 2),
        );
        r.get(
          '/posts/resource',
          (_) async => JsonResource.collection(
            await Post.definition.query().orderBy('id').paginate(perPage: 2),
            PostResource.new,
          ),
        );
        r.get(
          '/posts/resource/simple',
          (_) async => JsonResource.collection(
            await Post.definition
                .query()
                .orderBy('id')
                .simplePaginate(perPage: 2),
            PostResource.new,
          ),
        );
        r.get(
          '/posts/resource/cursor',
          (_) async => JsonResource.collection(
            await Post.definition
                .query()
                .orderBy('id')
                .cursorPaginate(perPage: 2),
            PostResource.new,
          ),
        );
        r.get(
          '/posts/{id}/resource',
          (req) async => PostResource(
            await Post.definition.query().findOrFail(req.param<int>('id')),
          ),
        );
        r.apiResource('photos', PhotoController());
      },
    )
    .create();

/// Boots [conformanceApp], migrates and returns a client.
Future<(Application, TestClient)> bootConformanceApp({
  Map<String, String> env = const {},
}) async {
  final app = conformanceApp(env: env);
  await app.boot();
  await app.run(() => App.make<Migrator>().run());
  return (app, TestClient(app));
}

/// Inserts [count] posts titled `Post 1`...
Future<void> seedPosts(Application app, int count) => app.run(() async {
  for (var i = 1; i <= count; i++) {
    await DB.table('posts').insert({'title': 'Post $i'});
  }
});
