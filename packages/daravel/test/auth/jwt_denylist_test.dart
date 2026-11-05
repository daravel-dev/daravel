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

  test(
    'application keys filling the process cache do not evict a revoked '
    'token (#169)',
    tags: 'security',
    () async {
      final channel = LocalCoordinatorChannel(
        createStandardCoordinator(processCacheMaxEntries: 10),
      );
      final app = await worker(channel);
      await app.run(() => App.make<Migrator>().run());
      final token = await app.run(() async {
        final user = await TestUser.definition.query().create({
          'name': 'Cy',
          'email': 'cy@x.io',
          'password': 'x',
        });
        return Auth.jwtGuard().issue(user);
      });
      await app.run(() => Auth.jwtGuard().invalidate(token));
      await app.run(() async {
        for (var i = 0; i < 11; i++) {
          await Cache.store('process').put('page:$i', i);
        }
        // The LRU process cache did evict: the first page is gone...
        expect(await Cache.store('process').get<int>('page:0'), isNull);
      });
      // ...but the revoked token is still refused.
      expect(await accepted(app, token), isFalse);
    },
  );

  test('a full denylist store evicts expired ids first and warns once '
      'before it drops a live one (#169)', () async {
    final warnings = <String>[];
    final coordinator = createStandardCoordinator(
      jwtDenylistMaxEntries: 2,
      onWarning: warnings.add,
    );
    final store = ProcessStore(
      LocalCoordinatorChannel(coordinator),
      service: ProcessCacheService.jwtDenylistServiceName,
    );
    Clock.freeze();
    addTearDown(Clock.restore);
    await store.put('expired', true, ttl: const Duration(seconds: 1));
    await store.put('a', true, ttl: const Duration(hours: 1));
    Clock.travel(const Duration(seconds: 2));
    await store.put('b', true, ttl: const Duration(hours: 1));
    expect(warnings, isEmpty, reason: 'only an expired id made room');
    expect(await store.get('a'), isTrue);
    await store.put('c', true, ttl: const Duration(hours: 1));
    await store.put('d', true, ttl: const Duration(hours: 1));
    expect(warnings, hasLength(1));
    expect(warnings.single, contains('JWT_DENYLIST_MAX_ENTRIES'));
    final stats = coordinator.stats()['services']! as Map<String, Object?>;
    expect(
      (stats[ProcessCacheService.jwtDenylistServiceName]!
          as Map)['live_evictions'],
      2,
    );
  });
}
