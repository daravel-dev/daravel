import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';

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
    // Scenario 13: a wide table like a Laravel `users` table that grew.
    await schema.create('wide_rows', (t) {
      t.id();
      for (var i = 1; i <= wideStringColumns; i++) {
        t.string('s$i').nullable();
      }
      for (var i = 1; i <= wideIntColumns; i++) {
        t.integer('n$i').nullable();
      }
      for (var i = 1; i <= wideDateColumns; i++) {
        t.timestamp('d$i').nullable();
      }
      t.boolean('active').defaultTo(true);
      t.decimal('balance', precision: 12).nullable();
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    await schema.dropIfExists('wide_rows');
    await schema.dropIfExists('comments');
    await schema.dropIfExists('posts');
    await schema.dropIfExists('users');
  }
}

/// Password of every seeded user (bcrypt, cost from `BCRYPT_ROUNDS`).
const String benchPassword = 'bench-password';

/// The benchmarked application (BLUEPRINT_V2 §10.2 scenarios 1–6).
/// Top-level so supervisor workers can build it in their own isolates.
Application
createBenchApp() => Application.configure(basePath: Directory.current.path)
    .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
    .withDatabaseDriver('mariadb', MySqlDriver.fromConfig)
    .withMigrations(const [CreateBenchTables()])
    .withAuth(
      (auth) =>
          auth.token<User>('token', ModelUserProvider<User>(User.definition)),
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
              ? Response.json({'message': 'Invalid credentials.'}, status: 422)
              : Response.json({'ok': true});
        });
        // Scenario 7: a 64 KB multipart upload, parsed and read.
        r.post('/upload', (req) async {
          final file = (await req.file('file'))!;
          return {'name': file.clientName, 'size': (await file.bytes()).length};
        });
        // Scenario 13: every row of a 40-column table (row decoding and
        // JSON encoding dominate; `?php=1` adds the json_encode rewrite).
        r.get(
          '/wide',
          (req) async => Response.json(
            await DB.table('wide_rows').orderBy('id').get(),
            phpCompatible: req.query['php'] == '1',
          ),
        );
        // Scenario 8: an SSE response of ten events, read to its end.
        r.get(
          '/events',
          (_) => Response.sse(
            Stream<Object?>.fromIterable([
              for (var i = 0; i < 10; i++) {'n': i},
            ]),
            heartbeat: null,
          ),
        );
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
    final stamp = DateTime.utc(2026);
    for (var i = 1; i <= wideRowCount; i++) {
      await DB.table('wide_rows').insert({
        for (var c = 1; c <= wideStringColumns; c++)
          's$c': 'Value $c of row $i, café/$i',
        for (var c = 1; c <= wideIntColumns; c++) 'n$c': i * c,
        for (var c = 1; c <= wideDateColumns; c++)
          'd$c': stamp.add(Duration(minutes: i + c)),
        'active': i.isEven,
        'balance': '${i * 3}.25',
      });
    }
  });
});

/// Column counts of `wide_rows` (with `id`, `active` and `balance`: 40).
const int wideStringColumns = 22;
const int wideIntColumns = 10;
const int wideDateColumns = 5;

/// Rows seeded into `wide_rows`, all returned by scenario 13.
const int wideRowCount = 1000;
