import 'dart:io';

import 'package:daravel/daravel.dart';

/// `users` row of the benchmark database.
final class User extends Model with AuthenticatableModel {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
    fillable: ['name', 'email', 'password'],
    hidden: ['password'],
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;
}

/// `posts` row; eager loads `author` and `comments` (scenario 4).
final class Post extends Model {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    timestamps: false,
    relations: {
      'author': () =>
          BelongsTo<User>(() => User.definition, foreignKey: 'user_id'),
      'comments': () =>
          HasMany<Comment>(() => Comment.definition, foreignKey: 'post_id'),
    },
  );

  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;
}

final class Comment extends Model {
  static final ModelDefinition<Comment> definition = ModelDefinition<Comment>(
    table: 'comments',
    factory: Comment.new,
    timestamps: false,
  );

  @override
  ModelDefinition<Comment> get modelDefinition => Comment.definition;
}

final class CreateBenchTables extends Migration {
  const CreateBenchTables();

  @override
  String get name => '2026_01_01_000000_create_bench_tables';

  @override
  Future<void> up(SchemaBuilder schema) async {
    await schema.create('users', (t) {
      t.id();
      t.string('name');
      t.string('email');
      t.string('password');
      t.timestamps();
    });
    await schema.create('posts', (t) {
      t.id();
      t.foreignId('user_id');
      t.string('title');
    });
    await schema.create('comments', (t) {
      t.id();
      t.foreignId('post_id').index();
      t.string('body');
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    await schema.dropIfExists('comments');
    await schema.dropIfExists('posts');
    await schema.dropIfExists('users');
  }
}

/// Password of every seeded user (bcrypt, cost from `BCRYPT_ROUNDS`).
const String benchPassword = 'bench-password';

/// The benchmarked application (BLUEPRINT_V2 §10.2 scenarios 1–6).
/// Top-level so supervisor workers can build it in their own isolates.
Application createBenchApp() =>
    Application.configure(basePath: Directory.current.path)
        .withMigrations(const [CreateBenchTables()])
        .withAuth(
          (auth) => auth.token<User>(
            'token',
            ModelUserProvider<User>(User.definition),
          ),
        )
        .withRateLimits(
          (limiter) => limiter.define(
            'bench',
            (request) => Limit.perMinute(1 << 30).by(request.ip),
          ),
        )
        .withRouting(
          apiPrefix: '/api',
          health: '/up',
          web: (r) => r.get('/ping', (_) => Response.text('pong')),
          api: (r) {
            r.get(
              '/users/{id}',
              (req) => User.definition.query().findOrFail(req.param<int>('id')),
            );
            r.post('/users', (req) async {
              final data = await req.validate({
                'name': 'required|string|max:255',
                'email': 'required|email|max:255',
              });
              return DB.transaction(
                () => User.definition.query().create({
                  ...data.toMap(),
                  'password': 'x',
                }),
              );
            });
            r.get(
              '/posts',
              (_) => Post.definition
                  .query()
                  .with_(const ['author', 'comments'])
                  .orderBy('id')
                  .limit(20)
                  .get(),
            );
            r.get('/throttled', (_) => Response.text('ok')).middleware(const [
              'throttle:bench',
            ]);
            r.post('/login', (req) async {
              final user = await Auth.retrieveByCredentials<User>({
                'email': 'user1@bench.test',
                'password': benchPassword,
              });
              return user == null
                  ? Response.json({
                      'message': 'Invalid credentials.',
                    }, status: 422)
                  : Response.json({'ok': true});
            });
          },
        )
        .create();

/// Creates the schema and seeds 1 000 users, 200 posts and 2 000 comments.
Future<void> seedBenchDatabase(Application app) => app.run(() async {
  await App.make<Migrator>().reset();
  await App.make<Migrator>().run();
  final password = await Hash.make(benchPassword, driver: .bcrypt);
  await DB.transaction(() async {
    for (var i = 1; i <= 1000; i++) {
      await DB.table('users').insert({
        'name': 'User $i',
        'email': 'user$i@bench.test',
        'password': password,
      });
    }
    for (var i = 1; i <= 200; i++) {
      await DB.table('posts').insert({'user_id': i, 'title': 'Post $i'});
      for (var c = 1; c <= 10; c++) {
        await DB.table('comments').insert({'post_id': i, 'body': 'Comment $c'});
      }
    }
  });
});
