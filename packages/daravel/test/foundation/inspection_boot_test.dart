import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A provider that queries the database while booting.
final class _QueriesAtBoot extends ServiceProvider {
  @override
  Future<void> boot(Container container) async {
    await DB.table('users').count();
  }
}

/// `Application.bootForInspection` (W9.6, `names:sync`):
/// the registrations are read, nothing connects.
void main() {
  var connects = 0;

  Application build({List<ServiceProvider> providers = const []}) =>
      Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'METRICS_ENABLED': 'true',
          })
          // A driver that counts (and refuses) every attempt to connect.
          .withDatabaseDriver('sqlite', (name, config) {
            connects++;
            throw StateError('connected to [$name]');
          })
          .withProviders(providers)
          .withRouting(
            api: (r) => r
                .get('/posts/{post}', (_) async => {'ok': true})
                .name('posts.show'),
          )
          .create();

  setUp(() => connects = 0);

  test('no connection is opened, by any name or through DB', () async {
    final app = build();
    await app.bootForInspection();
    addTearDown(app.shutdown);
    expect(app.inspecting, isTrue);
    await app.run(() async {
      for (final open in [
        () => DB.connection(),
        () => DB.connection('sqlite'),
        () => DB.connection('reporting'),
        () => DB.table('users').count(),
      ]) {
        await expectLater(
          open(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              contains('booted for inspection'),
            ),
          ),
        );
      }
    });
    // Refused before the driver factory ran.
    expect(connects, 0);
  });

  test('a provider that queries at boot fails with the reason', () async {
    final app = build(providers: [_QueriesAtBoot()]);
    addTearDown(app.shutdown);
    await expectLater(
      app.bootForInspection(),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('refused'), contains('booted for inspection')),
        ),
      ),
    );
    expect(connects, 0);
  });

  test('an application booted to run cannot be inspected', () async {
    final app = build();
    await app.boot();
    addTearDown(app.shutdown);
    expect(app.bootForInspection, throwsStateError);
  });

  test('the registrations are there to read', () async {
    final app = build();
    await app.bootForInspection();
    addTearDown(app.shutdown);
    final names = app.container.make<Router>().routes.map((r) => r.routeName);
    expect(names, contains('posts.show'));
  });

  group('routeUrl', () {
    test('in a running application, as router.url', () async {
      final app = build();
      await app.bootForInspection();
      addTearDown(app.shutdown);
      await app.run(() async {
        expect(
          routeUrl('posts.show', params: {'post': 7}, query: {'q': 'a'}),
          '/api/posts/7?q=a',
        );
      });
    });

    test('outside one, a StateError that says so', () {
      expect(
        () => routeUrl('posts.show'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('needs a booted Application'),
          ),
        ),
      );
    });
  });
}
