import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' hide Hash;
import 'package:daravel/daravel.dart';
import 'package:daravel_session/daravel_session.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

const String appKey = 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const String cookie = 'my_app_session';

final class User extends Model with AuthenticatableModel {
  static final ModelDefinition<User> definition = ModelDefinition<User>(
    table: 'users',
    factory: User.new,
    fillable: ['name', 'email', 'password'],
    hidden: ['password'],
  );

  @override
  ModelDefinition<User> get modelDefinition => User.definition;

  int get id => getAttr('id');
}

final class CreateUsers extends Migration {
  const CreateUsers();

  @override
  String get name => '2026_01_01_000000_create_users';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('users', (table) {
    table.id();
    table.string('name');
    table.string('email').unique();
    table.string('password');
    table.timestamps();
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('users');
}

void main() {
  late Directory base;
  late Application app;
  late TestClient client;
  late String loginKey;
  late Map<String, String> jar;

  Application build(Map<String, String> env) =>
      Application.configure(basePath: base.path)
          .withEnv({
            'APP_ENV': 'testing',
            'APP_NAME': 'My App',
            'APP_KEY': appKey,
            'DB_DATABASE': ':memory:',
            'SESSION_DRIVER': 'array',
            ...env,
          })
          .withLogLevel(LogLevel.warning)
          .withSession(csrfExcept: const ['*'])
          .withMigrations(const [CreateUsers()])
          .withAuth(
            (auth) => auth.session<User>(
              'web',
              ModelUserProvider<User>(User.definition),
            ),
          )
          .withRouting(
            web: (router) => router.group((r) {
              SessionGuard<User> guard() =>
                  App.make<AuthManager>().guard('web') as SessionGuard<User>;
              r.post('/login', (request) async {
                final ok = await guard().attempt({
                  'email': await request.input<String>('email'),
                  'password': await request.input<String>('password'),
                });
                return {'ok': ok, 'id': request.session.id};
              });
              r.post('/logout-then-fail', (request) async {
                await guard().logout();
                throw const HttpException(500, 'after logout');
              });
              r.post('/logout', (request) async {
                await guard().logout();
                await request.session.invalidate();
                return {'still': await guard().check()};
              });
              r
                  .get(
                    '/me',
                    (request) async => {
                      'id': await guard().id(),
                      'session': request.session.id,
                      'all': request.session.all,
                    },
                  )
                  .middleware(['auth:web']);
              r.get('/remember', (request) async {
                await guard().login(User(), remember: true);
                return {};
              });
            }, middleware: const ['web']),
          )
          .create();

  Future<void> start([Map<String, String> env = const {}]) async {
    app = build(env);
    await app.boot();
    await app.run(() async {
      await App.make<Migrator>().run();
      await User.definition.query().create({
        'name': 'Ana',
        'email': 'ana@x.io',
        'password': await Hash.make('secret'),
      });
    });
    client = TestClient(app);
    jar = {};
  }

  /// Keeps the session cookie between requests, as a browser.
  Map<String, String> headers() => {
    'accept': 'application/json',
    if (jar[cookie] != null)
      'cookie': '$cookie=${Uri.encodeComponent(jar[cookie]!)}',
  };

  T keep<T extends TestResponse>(T response) {
    for (final line in response.headers.all('set-cookie')) {
      if (line.startsWith('$cookie=')) {
        final end = line.indexOf(';');
        jar[cookie] = Uri.decodeComponent(
          line.substring(cookie.length + 1, end),
        );
      }
    }
    return response;
  }

  Future<TestResponse> login([String password = 'secret']) async => keep(
    await client.post(
      '/login',
      json: {'email': 'ana@x.io', 'password': password},
      headers: headers(),
    ),
  );

  setUp(() async {
    base = Directory.systemTemp.createTempSync('daravel_guard');
    loginKey =
        'login_web_${sha1.convert(utf8.encode(r'Illuminate\Auth\SessionGuard'))}';
    await start();
  });

  tearDown(() async {
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  test('the session key is Laravel\'s', () {
    final guard = SessionGuard<User>(
      name: 'web',
      provider: ModelUserProvider<User>(User.definition),
    );
    expect(guard.sessionKey, loginKey);
    expect(guard.passwordHashKey, 'password_hash_web');
  });

  test('a guest gets 401', () async {
    expect((await client.get('/me', headers: headers())).status, 401);
  });

  test('wrong credentials log nobody in', () async {
    expect((await login('nope')).jsonMap['ok'], isFalse);
    expect((await client.get('/me', headers: headers())).status, 401);
  });

  test('login stores the id under Laravel\'s key, with a new id', () async {
    final before = keep(await client.get('/me', headers: headers()));
    expect(before.status, 401);
    final first = await login();
    expect(first.jsonMap['ok'], isTrue);

    final me = keep(await client.get('/me', headers: headers()));
    me.assertOk();
    expect(me.jsonMap['id'], 1);
    final all = me.jsonMap['all']! as Map;
    expect(all[loginKey], 1);
  });

  test('password_hash_web as Laravel 12 and 13 write it', () async {
    await login();
    final me = keep(await client.get('/me', headers: headers()));
    final all = me.jsonMap['all']! as Map;
    final hash = await app.run(() async {
      final user = await User.definition.query().find(1);
      return user!.authPassword!;
    });
    expect(
      all['password_hash_web'],
      '${Hmac(sha256, utf8.encode(appKey)).convert(utf8.encode(hash))}',
    );
  });

  test('Laravel 11 and older keep no password hash on login', () async {
    await app.shutdown();
    await start(const {'COMPAT_LARAVEL_VERSION': '11'});
    await login();
    final me = keep(await client.get('/me', headers: headers()));
    expect(
      (me.jsonMap['all']! as Map).containsKey('password_hash_web'),
      isFalse,
    );
  });

  test('a session Laravel wrote is a login here', () async {
    const id = 'LaravelWroteThisSessionIdOfFortyChars123';
    final handler =
        app.container.make<SessionManager>().handler as ArraySessionHandler;
    await handler.write(id, jsonEncode({'_token': 't' * 40, loginKey: 1}));
    final encrypted = await app.run(() async {
      final encrypter = Crypt.encrypter;
      final prefix = CookieValuePrefix.create(cookie, encrypter.key);
      return encrypter.encryptString('$prefix$id');
    });
    final me = await client.get(
      '/me',
      headers: {'cookie': '$cookie=${Uri.encodeComponent(encrypted)}'},
    );
    expect(me.jsonMap['id'], 1);
  });

  test('a logout holds when the handler fails afterwards', () async {
    await login();
    final failed = keep(
      await client.post('/logout-then-fail', headers: headers()),
    );
    expect(failed.status, 500);
    expect((await client.get('/me', headers: headers())).status, 401);
  });

  test('logout ends it', () async {
    await login();
    final out = keep(await client.post('/logout', headers: headers()));
    expect(out.jsonMap['still'], isFalse);
    expect((await client.get('/me', headers: headers())).status, 401);
  });

  test('"remember me" is refused rather than ignored', () async {
    final response = await client.get('/remember', headers: headers());
    expect(response.status, 500);
  });

  test('the guard needs a session', () async {
    await app.run(() async {
      final guard = SessionGuard<User>(
        name: 'web',
        provider: ModelUserProvider<User>(User.definition),
      );
      expect(() => guard.logout(), throwsStateError);
      expect(await guard.check(), isFalse);
    });
  });
}
