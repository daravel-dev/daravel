import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class TestUser extends Model with AuthenticatableModel {
  static final ModelDefinition<TestUser> definition = ModelDefinition<TestUser>(
    table: 'users',
    factory: TestUser.new,
    fillable: ['name', 'email', 'password'],
    hidden: ['password'],
  );

  @override
  ModelDefinition<TestUser> get modelDefinition => TestUser.definition;

  static ModelQuery<TestUser> query() => definition.query();

  int get id => getAttr('id');
  String get email => getAttr('email');
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

final class UserPolicy extends Policy<TestUser> {
  const UserPolicy();

  @override
  Object? update(Authenticatable? user, TestUser model) =>
      user is TestUser && user.id == model.id;
}

final class Res {
  const Res(this.status, this.headers, this.json);
  final int status;
  final Headers headers;
  final Object? json;
}

void main() {
  late Application app;
  late TestUser ana;
  late TestUser bo;

  setUp(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'APP_KEY': Encrypter.generateKey(),
          'HASH_DRIVER': 'bcrypt',
        })
        .withMigrations(const [
          CreateUsers(),
          CreatePersonalAccessTokensTable(),
        ])
        .withAuth((auth) {
          final provider = ModelUserProvider<TestUser>(TestUser.definition);
          auth.token<TestUser>('token', provider);
          auth.jwt<TestUser>('jwt', provider, denylist: MemoryJwtDenylist());
        })
        .withPolicies((gate) => gate.policy<TestUser>(const UserPolicy()))
        .withRateLimits(
          (limiter) => limiter.define('tiny', (_) => Limit.perMinute(1)),
        )
        .withRouting(
          apiPrefix: '',
          api: (router) {
            router
                .get('/me', (req) async {
                  final user = await req.user<TestUser>();
                  return {'id': user!.id, 'guard': Auth.manager.guard().name};
                })
                .middleware(['auth']);
            router
                .get('/jwt-me', (req) async {
                  final user = await Auth.user<TestUser>();
                  return {
                    'id': user!.id,
                    'jti': (await Auth.jwtGuard().claims())!.jti,
                  };
                })
                .middleware(['auth:jwt']);
            router
                .get('/either', (req) async {
                  return {'guard': Auth.manager.guard().name};
                })
                .middleware(['auth:token,jwt']);
            router
                .get('/abilities', (req) async {
                  final guard = Auth.tokenGuard();
                  return {
                    'read': await guard.tokenCan('posts:read'),
                    'write': await guard.tokenCan('posts:write'),
                    'name': (await guard.currentAccessToken())!.name,
                  };
                })
                .middleware(['auth']);
            router
                .post('/logout', (req) async {
                  await Auth.tokenGuard().revokeCurrent();
                  return {'ok': true, 'still': await Auth.check()};
                })
                .middleware(['auth']);
            router.get('/limited', (_) => 'ok').middleware(['throttle:tiny']);
            router.bind(
              'user',
              (value, _) => TestUser.query().findOrFail(value),
            );
            router
                .patch(
                  '/users/{user}',
                  (req) => {'updated': req.binding<TestUser>('user').id},
                )
                .middleware(['auth', 'can:update,user']);
          },
        )
        .create();
    await app.boot();
    await app.run(() async {
      await App.make<Migrator>().run();
      final hash = await Hash.make('secret');
      ana = await TestUser.query().create({
        'name': 'Ana',
        'email': 'ana@x.io',
        'password': hash,
      });
      bo = await TestUser.query().create({
        'name': 'Bo',
        'email': 'bo@x.io',
        'password': hash,
      });
    });
  });

  tearDown(() => app.shutdown());

  Future<Res> send(Request request) async {
    final response = await app.handle(request);
    final text = await response.bodyText();
    Object? json;
    try {
      json = text.isEmpty ? null : jsonDecode(text);
    } on FormatException {
      json = text;
    }
    return Res(response.status, response.headers, json);
  }

  Future<Res> get(String path, {String? token}) => send(
    Request.fake(
      path: path,
      headers: {if (token != null) 'authorization': 'Bearer $token'},
    ),
  );

  test(
    'token guard: 401 without token, user resolved with a valid token',
    () async {
      final denied = await get('/me');
      expect(denied.status, 401);
      expect(denied.json, {'message': 'Unauthenticated.'});

      final issued = await app.run(() => Auth.issueToken(ana, 'cli'));
      expect(issued.plainTextToken, matches(RegExp(r'^\d+\|[A-Za-z0-9]{40}$')));
      final ok = await get('/me', token: issued.plainTextToken);
      expect(ok.status, 200);
      expect(ok.json, {'id': ana.id, 'guard': 'token'});

      final tampered =
          '${issued.plainTextToken.substring(0, issued.plainTextToken.length - 1)}x';
      expect((await get('/me', token: tampered)).status, 401);
      expect((await get('/me', token: 'garbage')).status, 401);
    },
  );

  test('abilities, last_used_at and revocation', () async {
    final token = await app.run(
      () => Auth.issueToken(ana, 'mobile', abilities: ['posts:read']),
    );
    final abilities = (await get(
      '/abilities',
      token: token.plainTextToken,
    )).json;
    expect(abilities, {'read': true, 'write': false, 'name': 'mobile'});

    final row = await app.run(
      () => DB
          .table('personal_access_tokens')
          .where('id', token.accessToken.id)
          .first(),
    );
    expect(row!['last_used_at'], isNotNull);
    expect(row['tokenable_type'], 'TestUser');
    expect(row['token'], hasLength(64));

    final logout = await get('/logout', token: token.plainTextToken);
    expect(logout.status, 405); // GET on a POST route
    final out = await send(
      Request.fake(
        method: 'POST',
        path: '/logout',
        headers: {'authorization': 'Bearer ${token.plainTextToken}'},
      ),
    );
    expect(out.json, {'ok': true, 'still': false});
    expect((await get('/me', token: token.plainTextToken)).status, 401);
  });

  test('expired tokens are rejected and pruned', () async {
    final expired = await app.run(
      () => Auth.issueToken(
        ana,
        'old',
        expiresAt: DateTime.now().toUtc().subtract(const Duration(minutes: 1)),
      ),
    );
    expect((await get('/me', token: expired.plainTextToken)).status, 401);
    final pruned = await app.run(() => Auth.tokenGuard().pruneExpired());
    expect(pruned, 1);
    await app.run(() async {
      expect(await Auth.tokenGuard().tokens(ana), isEmpty);
      await Auth.issueToken(ana, 'a');
      await Auth.issueToken(ana, 'b');
      expect(await Auth.tokenGuard().tokens(ana), hasLength(2));
      expect(await Auth.tokenGuard().revokeAll(ana), 2);
    });
  });

  test('jwt guard and multi-guard auth:token,jwt', () async {
    final jwt = await app.run(() => Auth.issueJwt(ana));
    final me = await get('/jwt-me', token: jwt);
    expect(me.status, 200);
    expect((me.json as Map<String, Object?>)['id'], ana.id);
    expect((me.json as Map<String, Object?>)['jti'], isNotNull);
    // A JWT is not a personal access token and vice versa.
    expect((await get('/me', token: jwt)).status, 401);
    expect((await get('/either', token: jwt)).json, {'guard': 'jwt'});
    final pat = await app.run(() => Auth.issueToken(ana, 'x'));
    expect((await get('/either', token: pat.plainTextToken)).json, {
      'guard': 'token',
    });
    expect((await get('/either')).status, 401);

    await app.run(() => Auth.jwtGuard().invalidate(jwt));
    expect((await get('/jwt-me', token: jwt)).status, 401);
  });

  test(
    'credentials: validate, retrieveByCredentials, once, onceUsingId',
    () async {
      await app.run(() async {
        expect(
          await Auth.validate({'email': 'ana@x.io', 'password': 'secret'}),
          isTrue,
        );
        expect(
          await Auth.validate({'email': 'ana@x.io', 'password': 'nope'}),
          isFalse,
        );
        expect(
          await Auth.validate({'email': 'ghost@x.io', 'password': 'secret'}),
          isFalse,
        );
        final found = await Auth.retrieveByCredentials<TestUser>({
          'email': 'bo@x.io',
          'password': 'secret',
        });
        expect(found?.email, 'bo@x.io');
        expect(await Auth.check(), isFalse);
        expect(
          await Auth.once({'email': 'ana@x.io', 'password': 'secret'}),
          isTrue,
        );
        expect(await Auth.check(), isTrue);
        expect(await Auth.id(), ana.id);
        Auth.forgetUser();
        expect(await Auth.guest(), isTrue);
        expect((await Auth.onceUsingId<TestUser>(bo.id))?.email, 'bo@x.io');
        expect(await Auth.id(), bo.id);
      });
    },
  );

  test('Gate and can: middleware use the authenticated user', () async {
    final anaToken = await app.run(() => Auth.issueToken(ana, 't'));
    final boToken = await app.run(() => Auth.issueToken(bo, 't'));
    Future<Res> patch(String token, int id) => send(
      Request.fake(
        method: 'PATCH',
        path: '/users/$id',
        headers: {'authorization': 'Bearer $token'},
      ),
    );
    expect((await patch(anaToken.plainTextToken, ana.id)).json, {
      'updated': ana.id,
    });
    final forbidden = await patch(boToken.plainTextToken, ana.id);
    expect(forbidden.status, 403);
    expect(forbidden.json, {'message': 'This action is unauthorized.'});
    expect((await patch(anaToken.plainTextToken, 999)).status, 404);

    await app.run(() async {
      Auth.setUser(ana);
      expect(await Gate.allows('update', [ana]), isTrue);
      expect(await Gate.allows('update', [bo]), isFalse);
      expect(await Gate.forUser(bo).allows('update', [bo]), isTrue);
    });
  });

  test('throttle alias is wired with named limiters', () async {
    expect((await get('/limited')).status, 200);
    final blocked = await get('/limited');
    expect(blocked.status, 429);
    expect(blocked.headers['retry-after'], isNotNull);
    expect(blocked.json, {'message': 'Too Many Attempts.'});
  });

  test('Hash and Crypt facades are bound', () async {
    await app.run(() async {
      final hashed = await Hash.make('pw');
      expect(Hash.info(hashed).driver, HashDriver.bcrypt);
      expect(await Hash.check('pw', hashed), isTrue);
      final payload = await Crypt.encryptString('top secret');
      expect(await Crypt.decryptString(payload), 'top secret');
      expect(
        await Crypt.decrypt<Map<String, Object?>>(
          await Crypt.encrypt({'a': 1}),
        ),
        {'a': 1},
      );
    });
  });
}
