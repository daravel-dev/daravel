// The Daravel side of bench/interop/laravel_matrix.sh: one step per run, on
// the SQLite database a Laravel 8 to 13 application uses too. The settings
// (COMPAT_LARAVEL_VERSION, SESSION_*, DB_*) come from the environment.
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_session/daravel_session.dart';
import 'package:daravel_test/daravel_test.dart';

const String cookieName = 'interop_session';

final class User extends Model with AuthenticatableModel {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;
}

/// The Laravel side's `Exam`.
final class Exam extends Model {
  static final ModelDefinition<Exam> definition = ModelDefinition<Exam>(
    table: 'exams',
    factory: Exam.new,
    timestamps: false,
    casts: {'price': Cast.decimalString(2), 'ratio': Cast.decimalString(3)},
  );

  @override
  ModelDefinition<Exam> get modelDefinition => Exam.definition;
}

final class Author extends Model {
  static final ModelDefinition<Author> definition = ModelDefinition<Author>(
    table: 'authors',
    factory: Author.new,
    timestamps: false,
  );

  @override
  ModelDefinition<Author> get modelDefinition => Author.definition;
}

final class Comment extends Model {
  static final ModelDefinition<Comment> definition = ModelDefinition<Comment>(
    table: 'comments',
    factory: Comment.new,
    timestamps: false,
    relations: {
      'author': () =>
          BelongsTo<Author>(() => Author.definition, foreignKey: 'author_id'),
    },
  );

  @override
  ModelDefinition<Comment> get modelDefinition => Comment.definition;
}

final class Post extends Model {
  static final ModelDefinition<Post> definition = ModelDefinition<Post>(
    table: 'posts',
    factory: Post.new,
    timestamps: false,
    relations: {
      'author': () =>
          BelongsTo<Author>(() => Author.definition, foreignKey: 'author_id'),
      'comments': () =>
          HasMany<Comment>(() => Comment.definition, foreignKey: 'post_id'),
    },
  );

  @override
  ModelDefinition<Post> get modelDefinition => Post.definition;
}

final class AuthorResource extends JsonApiResource<Author> {
  AuthorResource(super.resource);

  @override
  String toType(Request? request) => 'authors';

  @override
  Map<String, Object?> toAttributes(Request? request) => {
    'name': resource.getAttr<String>('name'),
  };
}

final class CommentResource extends JsonApiResource<Comment> {
  CommentResource(super.resource);

  @override
  String toType(Request? request) => 'comments';

  @override
  Map<String, Object?> toAttributes(Request? request) => {
    'body': resource.getAttr<String>('body'),
    'stars': resource.getAttr<int>('stars'),
  };

  @override
  Map<String, JsonApiRelationship<Model>> toRelationships(Request? request) => {
    'author': JsonApiRelationship<Author>(AuthorResource.new),
  };
}

final class PostResource extends JsonApiResource<Post> {
  PostResource(super.resource);

  @override
  String toType(Request? request) => 'posts';

  @override
  Map<String, Object?> toAttributes(Request? request) => {
    'title': resource.getAttr<String>('title'),
    'body': resource.getAttr<String>('body'),
  };

  @override
  Map<String, JsonApiRelationship<Model>> toRelationships(Request? request) => {
    'author': JsonApiRelationship<Author>(AuthorResource.new),
    'comments': JsonApiRelationship<Comment>(CommentResource.new),
  };

  @override
  Map<String, Object?> toLinks(Request? request) => {
    'self': '/posts/${resource.key}',
  };

  @override
  Map<String, Object?> toMeta(Request? request) => {'views': 3};
}

Author author(int id, String name) =>
    Author()..forceFill({'id': id, 'name': name});

Comment comment(int id, String body, Author by) => Comment()
  ..forceFill({'id': id, 'body': body, 'stars': id * 2})
  ..setRelation('author', by);

Post post(int id, Author? by, List<Comment> comments) => Post()
  ..forceFill({'id': id, 'title': 'T$id', 'body': 'B$id'})
  ..setRelation('author', by)
  ..setRelation('comments', comments);

Future<void> main(List<String> args) async {
  final app = Application.configure(basePath: Directory.current.path)
      .withSession()
      .withEnv({'LOG_LEVEL': 'error', 'SESSION_COOKIE': cookieName})
      .withAuth(
        (auth) =>
            auth.session<User>('web', ModelUserProvider<User>(User.definition)),
      )
      .withRouting(
        web: (router) {
          SessionGuard<User> guard() =>
              App.make<AuthManager>().guard('web') as SessionGuard<User>;
          router.group((r) {
            r.get('/touch', (request) {
              request.session.put('daravel', 'héllo');
              return {
                'id': request.session.id,
                'name': request.session.get<String>('name'),
                'status': request.session.get<String>('status'),
              };
            });
            r
                .get('/whoami', (request) async => {'user': await guard().id()})
                .middleware(['auth:web']);
            r.get('/invalid', (request) {
              throw ValidationException({
                'title': ['Title is required.'],
              });
            });
            r.get('/errors', (request) => {'errors': request.session.errors});
            r.get('/remember', (request) async {
              final ok = await guard().attempt({
                'email': 'ana@example.com',
                'password': 'secret',
              }, remember: true);
              return {'ok': ok};
            });
            r.get('/signin', (request) async {
              final ok = await guard().attempt({
                'email': 'ana@example.com',
                'password': 'secret',
              });
              request.session.put('daravel', 'héllo');
              return {'id': request.session.id, 'ok': ok};
            });
          }, middleware: const ['web']);
          router.post('/wire/validate', (request) async {
            await request.validate({
              'email': 'required|email',
              'name': 'required|min:3',
              'age': 'integer',
            });
            return {'ok': true};
          });
          router.post('/wire/terms', (request) async {
            await request.validate({
              'tos': 'accepted',
              'paid_tos': 'accepted_if:plan,paid,gold',
              'ads': 'declined',
              'calls': 'declined_if:plan,paid',
            });
            return {'ok': true};
          });
          final ana = author(1, 'Ana');
          final one = post(1, ana, [
            comment(1, 'c1', author(2, 'Budi')),
            comment(2, 'c2', ana),
          ]);
          final two = post(2, ana, []);
          router
            ..get('/jsonapi/post', (_) => PostResource(one))
            ..get('/jsonapi/empty', (_) => PostResource(two))
            ..get('/jsonapi/none', (_) => PostResource(post(3, null, [])))
            ..get(
              '/jsonapi/posts',
              (_) => JsonApiResource.collection<Post>([
                one,
                two,
              ], PostResource.new),
            )
            ..get(
              '/jsonapi/page',
              (_) => JsonApiResource.collection<Post>(
                LengthAwarePaginator<Post>(
                  items: [one, two],
                  total: 30,
                  perPage: 2,
                  currentPage: 2,
                  path: 'http://localhost/posts',
                ),
                PostResource.new,
              ),
            );
          router.get('/wire/model', (_) {
            final exam = Exam()
              ..forceFill({'id': 1, 'price': '12.5', 'ratio': '0.1255'})
              ..setRelation(
                'tipeUjian',
                Exam()..forceFill({'id': 2, 'price': '0.125', 'ratio': 3}),
              )
              ..setRelation('jenisSoal', null);
            return Response.json(exam.toJson());
          });
          router.get(
            '/wire/paginator',
            (_) => Response.json(
              LengthAwarePaginator<int>(
                items: const [1, 2],
                total: 30,
                perPage: 15,
                currentPage: 2,
                path: 'http://localhost/items',
              ).toJson(),
              // Laravel's default JsonResponse escapes `/`.
              phpCompatible: true,
            ),
          );
          router.bind('user', (_, _) async => null);
          router.get('/wire/bound/{user}', (_) => 'x').middleware(['auth:web']);
        },
      )
      .create();
  await app.boot();
  final client = TestClient(app);
  Map<String, String> cookie(List<String> args) => {
    if (args.length > 1)
      'cookie': '$cookieName=${Uri.encodeComponent(args[1])}',
  };
  const json = {'accept': 'application/json'};
  final out = await app.run(() async {
    switch (args.first) {
      case 'touch': // [cookie]: a request carrying Laravel's cookie, or none.
        return (await client.get('/touch', headers: cookie(args))).body;
      case 'invalid': // <cookie>: fails validation, as a browser.
        final response = await client.get(
          '/invalid',
          headers: {'accept': 'text/html', ...cookie(args)},
        );
        return jsonEncode({'status': response.status});
      case 'errors': // <cookie>
        return (await client.get('/errors', headers: cookie(args))).body;
      case 'whoami': // <cookie>
        final response = await client.get(
          '/whoami',
          headers: {...json, ...cookie(args)},
        );
        return response.body;
      case 'recall': // <cookie name> <cookie>
        final response = await client.get(
          '/whoami',
          headers: {
            ...json,
            'cookie': '${args[1]}=${Uri.encodeComponent(args[2])}',
          },
        );
        return response.body;
      case 'remember':
        final response = await client.get('/remember');
        final line = response.headers
            .all('set-cookie')
            .firstWhere((l) => l.startsWith('remember_web_'));
        final equals = line.indexOf('=');
        return jsonEncode({
          'name': line.substring(0, equals),
          'cookie': Uri.decodeComponent(
            line.substring(equals + 1, line.indexOf(';')),
          ),
        });
      case 'signin':
        return (await client.get('/signin')).body;
      case 'crypt':
        return jsonEncode({
          'encrypt': await Crypt.encrypt('fröm daravel'),
          'string': await Crypt.encryptString('fröm daravel'),
          'hash': await Hash.make('secret'),
        });
      case 'decrypt': // <encrypt payload> <encryptString payload> <hash>
        return jsonEncode({
          'encrypt': await Crypt.decrypt<String>(args[1]),
          'string': await Crypt.decryptString(args[2]),
          'hash': await Hash.check('secret', args[3]),
        });
      case 'wire':
        final responses = [
          await client.post(
            '/wire/validate',
            json: {'email': 'x', 'age': 'a'},
            headers: json,
          ),
          await client.get('/wire/nope', headers: json),
          await client.get('/wire/validate', headers: json),
          await client.post(
            '/wire/terms',
            json: {'plan': 'gold', 'tos': 'no', 'ads': 'yes'},
            headers: json,
          ),
          await client.get('/wire/model', headers: json),
          await client.get('/wire/paginator', headers: json),
          await client.get('/wire/bound/7', headers: json),
        ];
        return jsonEncode([
          for (final response in responses)
            {'status': response.status, 'body': response.body},
        ]);
      case 'jsonapi':
        return jsonEncode([
          for (final uri in const [
            '/jsonapi/post',
            '/jsonapi/post?include=author',
            '/jsonapi/post?include=comments',
            '/jsonapi/post?include=comments.author',
            '/jsonapi/post?include=author,comments.author',
            '/jsonapi/post?fields[posts]=title',
            '/jsonapi/post?fields[posts]=',
            '/jsonapi/post?include=comments&fields[comments]=body',
            '/jsonapi/post?include=nothing',
            '/jsonapi/empty?include=comments',
            '/jsonapi/none?include=author',
            '/jsonapi/posts?include=author',
            '/jsonapi/posts?include=comments.author',
            '/jsonapi/page?include=author',
          ])
            await () async {
              final response = await client.get(
                uri,
                headers: {'accept': 'application/vnd.api+json'},
              );
              return {
                'uri': uri,
                'status': response.status,
                'type': response.headers['content-type'],
                'body': response.body,
              };
            }(),
        ]);
      default:
        throw ArgumentError(args.first);
    }
  });
  await app.shutdown();
  stdout.writeln(out);
}
