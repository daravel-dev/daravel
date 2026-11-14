import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'auth_test.dart' show CreateUsers, TestUser;

/// A JWT without `exp` never expired: the codec required no claim and the
/// guard took any signed token. The guard now requires `exp` by default
/// (`JWT_REQUIRED_CLAIMS`, as tymon/jwt-auth's `required_claims`), and a
/// time claim that is there but not a number is refused (as
/// firebase/php-jwt).
void main() {
  const secret = 'a-very-long-secret-of-at-least-32-bytes!';
  final fixed = DateTime.utc(2026, 11, 14, 12);
  final epoch = fixed.millisecondsSinceEpoch ~/ 1000;
  JwtCodec codec({List<String> required = const []}) => JwtCodec(
    keys: [HmacJwtKey.fromString(secret)],
    clock: () => fixed,
    requiredClaims: required,
  );

  group('JwtCodec', () {
    test('nothing is required by default', () async {
      final token = await codec().sign({'sub': '1'});
      expect((await codec().verify(token)).subject, '1');
    });

    test('a required claim must be there, not null; exp, nbf and iat a '
        'number', () async {
      final strict = codec(required: ['exp', 'tenant']);
      for (final claims in <Map<String, Object?>>[
        {'sub': '1', 'tenant': 'a'},
        {'sub': '1', 'tenant': 'a', 'exp': null},
        {'sub': '1', 'exp': epoch + 60},
        {'sub': '1', 'exp': epoch + 60, 'tenant': null},
      ]) {
        final token = await strict.sign(claims);
        await expectLater(
          strict.verify(token),
          throwsA(isA<JwtException>()),
          reason: '$claims',
        );
        // Also when the times are not checked (revoking).
        await expectLater(
          strict.verify(token, checkTimes: false),
          throwsA(isA<JwtException>()),
          reason: '$claims',
        );
      }
      final ok = await strict.sign({'exp': epoch + 60, 'tenant': 'a'});
      expect((await strict.verify(ok))['tenant'], 'a');
    });

    test('a time claim that is there but not a number is refused, '
        'required or not', () async {
      for (final claims in <Map<String, Object?>>[
        {'exp': 'never'},
        {'exp': '9999999999'},
        {'nbf': true},
        {'iat': <Object?>[]},
        {'exp': <String, Object?>{}},
      ]) {
        final token = await codec().sign({'sub': '1', ...claims});
        await expectLater(
          codec().verify(token),
          throwsA(isA<JwtException>()),
          reason: '$claims',
        );
        // Whether the times are checked or not (revoking).
        await expectLater(
          codec().verify(token, checkTimes: false),
          throwsA(isA<JwtException>()),
          reason: '$claims, checkTimes: false',
        );
      }
    });

    test('a required claim of empty text counts as there, as in '
        'tymon/jwt-auth', () async {
      final strict = codec(required: ['iss']);
      final token = await strict.sign({'sub': '1', 'iss': ''});
      expect((await strict.verify(token)).issuer, '');
    });
  });

  group('the JWT guard', () {
    late Directory dir;
    late Application app;
    late TestUser ana;

    Future<void> boot(Map<String, String> env) async {
      dir = Directory.systemTemp.createTempSync('daravel_jwt_claims_');
      app = Application.configure(basePath: dir.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'APP_KEY': Encrypter.generateKey(),
            'JWT_SECRET': secret,
            ...env,
          })
          .withMigrations(const [CreateUsers()])
          .withAuth((auth) {
            auth.jwt<TestUser>(
              'jwt',
              ModelUserProvider<TestUser>(TestUser.definition),
            );
          })
          .withRouting(
            apiPrefix: '',
            api: (router) => router
                .get('/me', (req) async => {'ok': true})
                .middleware(['auth:jwt']),
          )
          .create();
      await app.boot();
      await app.run(() async {
        await App.make<Migrator>().run();
        ana = await TestUser.query().create({
          'name': 'Ana',
          'email': 'ana@example.test',
          'password': 'x',
        });
      });
    }

    tearDown(() async {
      await app.shutdown();
      Container.setRoot(null);
      dir.deleteSync(recursive: true);
    });

    Future<(int, String)> me(String token) async {
      final response = await app.handle(
        Request.fake(path: '/me', headers: {'authorization': 'Bearer $token'}),
      );
      return (response.status, await response.bodyText());
    }

    Future<String> sign(Map<String, Object?> claims) =>
        app.run(() => Auth.jwtGuard().codec.sign(claims));

    test('requires exp by default; its own tokens pass', () async {
      await boot({});
      expect(await app.run(() async => Auth.manager.config.jwtRequiredClaims), [
        'exp',
      ]);
      final noExp = await sign({'sub': '${ana.id}'});
      expect((await me(noExp)).$1, 401);
      final issued = await app.run(() => Auth.issueJwt(ana));
      expect((await me(issued)).$1, 200);
    });

    test('JWT_REQUIRED_CLAIMS set empty requires nothing', () async {
      await boot({'JWT_REQUIRED_CLAIMS': ''});
      final noExp = await sign({'sub': '${ana.id}'});
      expect((await me(noExp)).$1, 200);
    });

    test('its own tokens pass when nbf and iss are required too', () async {
      await boot({'JWT_REQUIRED_CLAIMS': 'exp, nbf, iss, jti, sub, iat'});
      final issued = await app.run(() => Auth.issueJwt(ana));
      expect((await me(issued)).$1, 200);
      final claims = JwtCodec.decodeUnverified(issued).payload;
      expect(claims.keys, containsAll(['exp', 'nbf', 'iss', 'jti', 'sub']));
    });

    test('a token without exp answers exactly as an expired or forged one '
        '(401, the same body)', () async {
      await boot({});
      final noExp = await sign({'sub': '${ana.id}'});
      final expired = await sign({'sub': '${ana.id}', 'exp': 1});
      final issued = await app.run(() => Auth.issueJwt(ana));
      final forged =
          '${issued.substring(0, issued.lastIndexOf('.'))}.'
          '${base64Url.encode(utf8.encode('x')).replaceAll('=', '')}';
      final answers = {
        for (final token in [noExp, expired, forged]) await me(token),
      };
      expect(answers, hasLength(1), reason: '$answers');
      expect(answers.single.$1, 401);
    });
  });

  group('JWT_REQUIRED_CLAIMS checks', () {
    Iterable<ConfigIssue> check(Map<String, String> values) {
      final env = Env.fromMap(values);
      final config = ConfigRepository()
        ..register(AppConfig.fromEnv(env))
        ..register(AuthConfig.fromEnv(env));
      return AuthConfig.check(env, config);
    }

    test('a name that is not a claim name is an error', () {
      final issues = check({'JWT_REQUIRED_CLAIMS': 'exp, bad claim'});
      expect(issues.single.level, ConfigIssueLevel.error);
    });

    test('a claim the guard does not write is a warning', () {
      final issues = check({'JWT_REQUIRED_CLAIMS': 'exp,tenant'});
      expect(issues.single.level, ConfigIssueLevel.warning);
      expect(issues.single.message, contains('tenant'));
      expect(
        check({'JWT_REQUIRED_CLAIMS': 'aud'}).single.level,
        ConfigIssueLevel.warning,
      );
      expect(
        check({'JWT_REQUIRED_CLAIMS': 'aud', 'JWT_AUDIENCE': 'api'}),
        isEmpty,
      );
    });

    test('requiring nothing in production is a warning', () {
      expect(
        check({'APP_ENV': 'production', 'JWT_REQUIRED_CLAIMS': ''})
            .single
            .level,
        ConfigIssueLevel.warning,
      );
      expect(check({'APP_ENV': 'local', 'JWT_REQUIRED_CLAIMS': ''}), isEmpty);
      expect(check({'APP_ENV': 'production'}), isEmpty);
    });
  });
}
