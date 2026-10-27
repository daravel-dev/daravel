import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'auth_test.dart' show CreateUsers, TestUser;

/// A revoked JWT must be refused by every worker isolate, not only by the
/// one that handled the logout: two applications on one coordinator are
/// two isolates of one server.
void main() {
  late Directory dir;
  final apps = <Application>[];

  Future<Application> worker(CoordinatorChannel channel) async {
    final app =
        Application.configure(basePath: dir.path)
            .withEnv({
              'APP_ENV': 'testing',
              'DB_DATABASE': '${dir.path}/app.sqlite',
              'APP_KEY': 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
              'JWT_TTL': '5',
            })
            .withMigrations(const [CreateUsers()])
            .withAuth(
              (auth) => auth.jwt<TestUser>(
                'jwt',
                ModelUserProvider<TestUser>(TestUser.definition),
              ),
            )
            .create()
          ..coordinator = channel;
    await app.boot();
    apps.add(app);
    return app;
  }

  setUp(() => dir = Directory.systemTemp.createTempSync('daravel_jwt_'));

  tearDown(() async {
    for (final app in apps) {
      await app.shutdown();
    }
    apps.clear();
    dir.deleteSync(recursive: true);
  });

  Future<bool> accepted(Application app, String token) => app.run(() async {
    final request = Request.fake(headers: {'authorization': 'Bearer $token'});
    return Container.current.runScoped('request', (scope) async {
      scope.put<Request>(request);
      return await Auth.guard('jwt').user() != null;
    });
  });

  test(
    'a token revoked on one isolate is refused on the others',
    tags: 'security',
    () async {
      final channel = LocalCoordinatorChannel(createStandardCoordinator());
      final first = await worker(channel);
      final second = await worker(channel);
      await first.run(() => App.make<Migrator>().run());

      final token = await first.run(() async {
        final user = await TestUser.definition.query().create({
          'name': 'Ana',
          'email': 'ana@x.io',
          'password': 'x',
        });
        return Auth.jwtGuard().issue(user);
      });
      expect(await accepted(second, token), isTrue);

      await first.run(() => Auth.jwtGuard().invalidate(token));
      expect(await accepted(first, token), isFalse);
      expect(await accepted(second, token), isFalse);
    },
  );

  test(
    'a revoked token stays refused through the leeway after it expires',
    tags: 'security',
    () async {
      final channel = LocalCoordinatorChannel(createStandardCoordinator());
      final app = await worker(channel);
      await app.run(() => App.make<Migrator>().run());
      final start = DateTime.now().toUtc();
      Clock.fake(start);
      addTearDown(Clock.restore);
      final token = await app.run(() async {
        final user = await TestUser.definition.query().create({
          'name': 'Bo',
          'email': 'bo@x.io',
          'password': 'x',
        });
        return Auth.jwtGuard().issue(user);
      });
      await app.run(() => Auth.jwtGuard().invalidate(token));
      // Five minutes and ten seconds: past `exp`, inside the 30 s leeway.
      Clock.travelTo(start.add(const Duration(minutes: 5, seconds: 10)));
      expect(await accepted(app, token), isFalse);
    },
  );
}
