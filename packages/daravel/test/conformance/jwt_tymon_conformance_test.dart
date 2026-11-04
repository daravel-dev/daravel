@Tags(['conformance'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import '../auth/auth_test.dart' show CreateUsers, TestUser;

/// Tokens shared with tymon/jwt-auth 2.2.1, Laravel's `jwt` guard with
/// `lock_subject` (its `config/jwt.php` default):
///
/// - `src/JWT.php` lines 250-255: `getClaimsForSubject` adds `sub` and,
///   with `lock_subject`, `prv` = `hashSubjectModel($subject)`;
/// - `src/JWT.php` lines 263-266: `hashSubjectModel` returns
///   `sha1(get_class($model))`;
/// - `src/JWT.php` lines 274-281: `checkSubjectModel` passes a token without
///   `prv` and compares it otherwise;
/// - `src/Factory.php` lines 44-50: the default claims `iss`, `iat`, `exp`,
///   `nbf`, `jti`, all required by `config/jwt.php` `required_claims` with
///   `sub`.
///
/// [tymonToken] was issued by that code (`JWTAuth::fromUser` for an
/// `App\Models\User` with id 7, HS256, ttl 16 days) with [secret], a test
/// secret.
const String secret = 'test-secret-of-the-daravel-tymon-fixture-0123456789';
const String tymonToken =
    'eyJ0eXAiOiJKV1QiLCJhbGciOiJIUzI1NiJ9.'
    'eyJpc3MiOiJodHRwOi8vbG9jYWxob3N0IiwiaWF0IjoxNzkzNzQ5MjE5LCJleHAiOjE3OTUx'
    'MzE2MTksIm5iZiI6MTc5Mzc0OTIxOSwianRpIjoickVVQmthQzJvZmdxa0VSVCIsInN1YiI6'
    'IjciLCJwcnYiOiIyM2JkNWM4OTQ5ZjYwMGFkYjM5ZTcwMWM0MDA4NzJkYjdhNTk3NmY3In0.'
    'QmD5WXOcvG7Z6du4HYiyKUemjGbkX7Kgq-tTR7GtPEM';
const int iat = 1793749219;
const int exp = 1795131619;
const String tymonPrv = '23bd5c8949f600adb39e701c400872db7a5976f7';

void main() {
  late Directory dir;
  final apps = <Application>[];

  setUp(() {
    dir = Directory.systemTemp.createTempSync('daravel_jwt_tymon_');
    Clock.fake(
      DateTime.fromMillisecondsSinceEpoch((iat + 60) * 1000, isUtc: true),
    );
  });

  tearDown(() async {
    Clock.restore();
    for (final app in apps) {
      await app.shutdown();
    }
    apps.clear();
    dir.deleteSync(recursive: true);
  });

  Future<Application> app({
    String? subjectClass,
    String? issuerClaim = 'http://localhost',
  }) async {
    final app = Application.configure(basePath: dir.path)
        .withEnv({
          'APP_ENV': 'testing',
          'APP_URL': 'https://app.example.test',
          'DB_DATABASE': ':memory:',
          'APP_KEY': 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          'JWT_SECRET': secret,
          'JWT_TTL': '${60 * 24 * 16}',
          'JWT_LEEWAY': '0',
          'JWT_ISSUER_CLAIM': ?issuerClaim,
          'JWT_SUBJECT_CLASS': ?subjectClass,
        })
        .withMigrations(const [CreateUsers()])
        .withAuth(
          (auth) => auth.jwt<TestUser>(
            'jwt',
            ModelUserProvider<TestUser>(TestUser.definition),
          ),
        )
        .create();
    await app.boot();
    apps.add(app);
    await app.run(() async {
      await App.make<Migrator>().run();
      await DB.table('users').insert({
        'id': 7,
        'name': 'Ana',
        'email': 'ana@x.io',
        'password': 'x',
      });
    });
    return app;
  }

  Future<Object?> userOf(Application app, String token) => app.run(() async {
    final request = Request.fake(headers: {'authorization': 'Bearer $token'});
    return Container.current.runScoped('request', (scope) async {
      scope.put<Request>(request);
      return (await Auth.guard('jwt').user())?.authIdentifier;
    });
  });

  Map<String, Object?> payloadOf(String token) => jsonDecode(
    utf8.decode(base64Url.decode(base64Url.normalize(token.split('.')[1]))),
  ) as Map<String, Object?>;

  test("tymon's prv is the sha1 of the model class name", () async {
    final a = await app(subjectClass: r'App\Models\User');
    expect(await a.run(() async => Auth.jwtGuard().subjectHash), tymonPrv);
  });

  test("a token issued by tymon/jwt-auth signs Laravel's user in", () async {
    final a = await app(subjectClass: r'App\Models\User');
    expect(await userOf(a, tymonToken), 7);
  });

  test('a prv for another model class is refused', () async {
    final a = await app(subjectClass: r'App\Models\Admin');
    expect(await userOf(a, tymonToken), isNull);
  });

  test(
    'without JWT_SUBJECT_CLASS, prv is neither written nor checked',
    () async {
      final a = await app();
      expect(await userOf(a, tymonToken), 7);
      final issued = await a.run(() async {
        final user = (await TestUser.definition.query().find(7))!;
        return Auth.jwtGuard().issue(user);
      });
      final payload = payloadOf(issued);
      expect(payload.keys, isNot(contains('prv')));
      expect(payload.keys, isNot(contains('nbf')));
    },
  );

  test('a Daravel token carries every claim tymon requires', () async {
    final a = await app(subjectClass: r'App\Models\User');
    final issued = await a.run(() async {
      final user = (await TestUser.definition.query().find(7))!;
      return Auth.jwtGuard().issue(user);
    });
    final payload = payloadOf(issued);
    // config/jwt.php required_claims, plus prv for lock_subject.
    expect(
      payload.keys,
      containsAll(['iss', 'iat', 'exp', 'nbf', 'sub', 'jti', 'prv']),
    );
    expect(payload['prv'], tymonPrv);
    expect(payload['sub'], '7');
    expect(payload['iss'], 'http://localhost');
    expect(payload['nbf'], payload['iat']);
    // JWT_TTL is in minutes, as tymon's ttl.
    expect(
      (payload['exp']! as int) - (payload['iat']! as int),
      60 * 24 * 16 * 60,
    );
    expect(await userOf(a, issued), 7);
  });

  test('without JWT_ISSUER_CLAIM, iss is the application URL', () async {
    final a = await app(subjectClass: r'App\Models\User', issuerClaim: null);
    final issued = await a.run(() async {
      final user = (await TestUser.definition.query().find(7))!;
      return Auth.jwtGuard().issue(user);
    });
    expect(payloadOf(issued)['iss'], 'https://app.example.test');
  });

  test('with JWT_LEEWAY=0 the token stops at exp, as in tymon', () async {
    final a = await app(subjectClass: r'App\Models\User');
    Clock.fake(
      DateTime.fromMillisecondsSinceEpoch((exp - 1) * 1000, isUtc: true),
    );
    expect(await userOf(a, tymonToken), 7);
    Clock.fake(DateTime.fromMillisecondsSinceEpoch(exp * 1000, isUtc: true));
    expect(await userOf(a, tymonToken), isNull);
  });
}
