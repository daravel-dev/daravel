import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

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
  test('parseDbDateTime reads text without a zone as UTC', () {
    // MySQL's `Y-m-d H:i:s`: written in UTC, whatever the process's zone.
    expect(
      parseDbDateTime('2026-11-04 17:21:31'),
      DateTime.utc(2026, 11, 4, 17, 21, 31),
    );
    expect(parseDbDateTime('2026-11-04 17:21:31')!.isUtc, isTrue);
    expect(
      parseDbDateTime('2026-11-04T17:21:31+08:00'),
      DateTime.utc(2026, 11, 4, 9, 21, 31),
    );
    expect(parseDbDateTime(0), DateTime.utc(1970));
    expect(parseDbDateTime(''), isNull);
    expect(parseDbDateTime(null), isNull);
  });

  var mineBinderCalls = 0;
  final bindingsSeen = <String, String?>{};
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
            router.bind('mine', (value, _) async {
              mineBinderCalls++;
              return '$value, logged in: ${await Auth.check()}';
            });
            String? seen(Request request) {
              try {
                return request.binding<String>('mine');
              } on StateError {
                return null;
              }
            }

            Middleware spy(String name) => FunctionalMiddleware((r, next) {
              bindingsSeen[name] = seen(r);
              return next(r);
            });
            router
                .get('/mine/{mine}', (req) => {'bound': seen(req)})
                .middleware([spy('before'), 'auth', spy('after')]);
            router
                .get('/mine-limited/{mine}', (req) => {'bound': seen(req)})
                .middleware(['throttle:tiny']);
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

  test('token guard: 401 without token, user resolved with a valid token', () async {
    final denied = await get('/me');
    expect(denied.status, 401);
    expect(denied.json, {'message': 'Unauthenticated.'});

    final issued = await app.run(() => Auth.issueToken(ana, 'cli'));
    // Sanctum 4: id|40 random chars + crc32b checksum.
    expect(
      issued.plainTextToken,
      matches(RegExp(r'^\d+\|[A-Za-z0-9]{40}[0-9a-f]{8}$')),
    );
    final ok = await get('/me', token: issued.plainTextToken);
    expect(ok.status, 200);
    expect(ok.json, {'id': ana.id, 'guard': 'token'});

    final tampered =
        '${issued.plainTextToken.substring(0, issued.plainTextToken.length - 1)}x';
    expect((await get('/me', token: tampered)).status, 401);
    expect((await get('/me', token: 'garbage')).status, 401);
  });

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
    expect(row['tokenable_type'], r'App\Models\TestUser');
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

  test('bindings run after auth and throttle, as SubstituteBindings', () async {
    mineBinderCalls = 0;
    bindingsSeen.clear();
    final guest = await send(Request.fake(path: '/mine/a'));
    expect(guest.status, 401);
    expect(mineBinderCalls, 0, reason: 'no query for a guest');

    final token = await app.run(() => Auth.issueToken(ana, 't'));
    final user = await send(
      Request.fake(
        path: '/mine/a',
        headers: {'authorization': 'Bearer ${token.plainTextToken}'},
      ),
    );
    expect(user.json, {'bound': 'a, logged in: true'});
    expect(bindingsSeen, {'before': null, 'after': 'a, logged in: true'});

    mineBinderCalls = 0;
    final passed = await send(Request.fake(path: '/mine-limited/a'));
    expect(passed.status, 200);
    expect(mineBinderCalls, 1);
    final blocked = await send(Request.fake(path: '/mine-limited/a'));
    expect(blocked.status, 429);
    expect(mineBinderCalls, 1, reason: 'no query past the rate limit');
  });

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
    final guest = await send(Request.fake(method: 'PATCH', path: '/users/999'));
    expect(guest.status, 401, reason: 'a guest learns nothing about 999');

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

  test('AU1: token abilities fail closed; a row of another shape is no '
      'error', () async {
    for (final (raw, abilities) in <(Object?, List<String>)>[
      ('["*"]', ['*']),
      ('["read"]', ['read']),
      ('[]', <String>[]),
      (null, <String>[]),
      ('', <String>[]),
      ('{bad', <String>[]),
      ('null', <String>[]),
      ('{"a":1}', <String>[]),
      ('[123]', <String>[]),
      ('["read",1,null]', ['read']),
      (Uint8List.fromList(utf8.encode('["read"]')), ['read']),
      (<Object?>['write', 2], ['write']),
      (42, <String>[]),
    ]) {
      expect(PersonalAccessToken.abilitiesOf(raw), abilities, reason: '$raw');
    }
    final token = await app.run(
      () => Auth.issueToken(ana, 'mobile', abilities: ['posts:read']),
    );
    for (final stored in <Object?>[null, '', '{bad', 'null', '[123]']) {
      await app.run(
        () => DB
            .table('personal_access_tokens')
            .where('id', token.accessToken.id)
            .update({'abilities': stored}),
      );
      final response = await get('/abilities', token: token.plainTextToken);
      expect(response.status, 200, reason: '$stored');
      expect(response.json, {
        'read': false,
        'write': false,
        'name': 'mobile',
      }, reason: '$stored: none, not every one');
    }
    // A row with null name and owner type reads, without an error.
    expect(
      PersonalAccessToken.fromRow({
        'id': 1,
        'tokenable_type': null,
        'tokenable_id': null,
        'name': null,
        'token': null,
        'abilities': '["*"]',
      }).name,
      '',
    );
  });

  test('AU2: invalidate verifies the token first', () async {
    final jwt = await app.run(() => Auth.issueJwt(ana));
    final jti = await app.run(
      () async => (await Auth.jwtGuard().codec.verify(jwt)).jti,
    );
    String b64(Object json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
    // Forged (alg none) with the real token's jti: refused, nothing revoked.
    final forged =
        '${b64({'alg': 'none', 'typ': 'JWT'})}.${b64({'jti': jti, 'sub': 1})}.';
    await expectLater(
      app.run(() => Auth.jwtGuard().invalidate(forged)),
      throwsA(isA<JwtException>()),
    );
    final signedBadSig =
        '${jwt.substring(0, jwt.lastIndexOf('.'))}.${b64({'x': 1})}';
    await expectLater(
      app.run(() => Auth.jwtGuard().invalidate(signedBadSig)),
      throwsA(isA<JwtException>()),
    );
    expect((await get('/jwt-me', token: jwt)).status, 200, reason: 'alive');
    // A jti that is no string, an exp no date holds: JwtException.
    for (final claims in [
      {'jti': 5},
      {'jti': 'x', 'exp': 1e308},
    ]) {
      final odd = await app.run(
        () => Auth.jwtGuard().codec.sign({...claims, 'sub': '${ana.id}'}),
      );
      await expectLater(
        app.run(() => Auth.jwtGuard().invalidate(odd)),
        throwsA(isA<JwtException>()),
        reason: '$claims',
      );
    }
    // An expired but signed token may still be revoked.
    final expired = await app.run(
      () => Auth.jwtGuard().codec.sign({
        'jti': 'old-one',
        'sub': '${ana.id}',
        'exp': DateTime.utc(2000).millisecondsSinceEpoch ~/ 1000,
      }),
    );
    await app.run(() => Auth.jwtGuard().invalidate(expired));
    // The real one still works, and revoking it works.
    await app.run(() => Auth.jwtGuard().invalidate(jwt));
    expect((await get('/jwt-me', token: jwt)).status, 401);
  });

  test('AU3: 100 000 random tokens: only JwtException, getters never '
      'throw, HTTP answers 401', () async {
    final random = Random(20261113);
    Object? value(int depth) => switch (random.nextInt(depth > 1 ? 7 : 9)) {
      0 => null,
      1 => random.nextBool(),
      2 => random.nextInt(1 << 31) - (1 << 30),
      3 => [1e308, -1e308, double.maxFinite, 1.5, -0.0][random.nextInt(5)],
      4 => 'k${random.nextInt(4)}',
      5 => String.fromCharCodes(
        List.generate(random.nextInt(8), (_) => random.nextInt(0x3000)),
      ),
      6 => ['HS256', 'EdDSA', 'none', 'RS256'][random.nextInt(4)],
      7 => [for (var i = random.nextInt(3); i > 0; i--) value(depth + 1)],
      _ => {
        for (var i = random.nextInt(3); i > 0; i--)
          'k${random.nextInt(5)}': value(depth + 1),
      },
    };
    String b64(Object? json) =>
        base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
    const headerKeys = ['alg', 'kid', 'typ'];
    const claimKeys = ['jti', 'iss', 'sub', 'aud', 'exp', 'nbf', 'iat'];
    await app.run(() async {
      final codec = Auth.jwtGuard().codec;
      for (var i = 0; i < 100000; i++) {
        final header = {
          for (final key in headerKeys)
            if (random.nextInt(4) != 0) key: value(0),
          if (i.isEven) 'alg': 'HS256',
        };
        final payload = {
          for (final key in claimKeys)
            if (random.nextInt(3) != 0) key: value(0),
        };
        final token = switch (i % 10) {
          0 => 'not.a.token$i',
          1 => '${b64(value(0))}.${b64(value(0))}.x',
          _ => '${b64(header)}.${b64(payload)}.${b64(value(0))}',
        };
        try {
          await codec.verify(token);
          fail('verified a random token: $token');
        } on JwtException {
          // Expected.
        } on Object catch (error) {
          fail('${error.runtimeType} from verify($token): $error');
        }
        try {
          final parts = JwtCodec.decodeUnverified(token);
          final claims = JwtClaims(parts.payload, header: parts.header);
          claims
            ..subject
            ..issuer
            ..jti
            ..kid
            ..expiresAt
            ..notBefore
            ..issuedAt;
        } on JwtException {
          // Malformed.
        } on Object catch (error) {
          fail('${error.runtimeType} from decode/claims($token): $error');
        }
      }
    });
    for (final claims in [
      {'kid': 5},
      {'exp': 1e308},
      {'jti': 5, 'iss': 7},
    ]) {
      final header = {
        'alg': 'HS256',
        ...claims.containsKey('kid') ? claims : const <String, Object>{},
      };
      final token = '${b64(header)}.${b64(claims)}.${b64('sig')}';
      expect(
        (await get('/jwt-me', token: token)).status,
        401,
        reason: '$claims',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
