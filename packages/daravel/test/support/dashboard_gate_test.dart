import 'dart:async';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `DashboardGate`, the one rule of every dashboard: local passes; else
/// the callback, else the gate; never middleware; never throws.
void main() {
  tearDown(() => Container.setRoot(null));

  Container containerFor(
    String env, {
    bool logger = true,
    AuthorizationGate? gate,
  }) {
    final config = ConfigRepository()
      ..register(
        AppConfig(
          name: 'Test',
          env: env,
          debug: false,
          url: 'http://localhost',
          timezone: 'UTC',
          locale: 'en',
        ),
      );
    final container = Container()..instance<ConfigRepository>(config);
    if (logger) {
      container.instance<Logger>(Logger(handlers: [MemoryHandler()]));
    }
    container.instance<AuthorizationGate>(
      gate ?? AuthorizationGate(userResolver: () async => null),
    );
    Container.setRoot(container);
    return container;
  }

  final request = Request.fake(path: '/dashboard');

  Future<bool> allows({FutureOr<bool> Function(Request)? callback}) =>
      DashboardGate.allows(
        request,
        ability: 'viewThing',
        name: 'Thing dashboard',
        callback: callback,
      );

  test('local passes without a callback or gate', () async {
    containerFor('local');
    expect(await allows(), isTrue);
    expect(await allows(callback: (_) => false), isTrue);
  });

  test('testing and production: no callback and no gate is no', () async {
    for (final env in ['testing', 'production', 'staging']) {
      containerFor(env);
      expect(await allows(), isFalse, reason: env);
    }
  });

  test('the callback decides before the gate', () async {
    final gate = AuthorizationGate(userResolver: () async => null)
      ..define('viewThing', (Authenticatable? user, _) => true);
    containerFor('production', gate: gate);
    expect(await allows(), isTrue);
    expect(await allows(callback: (_) => false), isFalse);
    expect(await allows(callback: (_) async => true), isTrue);
  });

  test('a gate that denies is no', () async {
    final gate = AuthorizationGate(userResolver: () async => null)
      ..define('viewThing', (Authenticatable? user, _) => false);
    containerFor('production', gate: gate);
    expect(await allows(), isFalse);
  });

  test('a callback or gate that throws is no, logged', () async {
    final container = containerFor('production');
    expect(await allows(callback: (_) => throw StateError('broken')), isFalse);
    final logged =
        (container.make<Logger>().handlers.single as MemoryHandler).records;
    expect(logged.single.message, contains('Thing dashboard authorization'));
    final gate = AuthorizationGate(
      userResolver: () async => null,
    )..define('viewThing', (Authenticatable? user, _) => throw StateError('x'));
    containerFor('production', gate: gate);
    expect(await allows(), isFalse);
  });

  test('never throws: no logger, no configuration, no container', () async {
    containerFor('production', logger: false);
    expect(await allows(callback: (_) => throw StateError('broken')), isFalse);
    Container.setRoot(Container());
    expect(await allows(), isFalse);
    Container.setRoot(null);
    expect(await allows(), isFalse);
  });

  group('middleware', () {
    test('without middleware: the web group when registered, else none', () {
      final registry = MiddlewareRegistry();
      List<Object> chosen() => DashboardGate.middleware(
        registry,
        null,
        setup: 'withThing',
        authHint: 'Thing.auth',
      );
      expect(chosen(), isEmpty);
      registry.group('web', const []);
      expect(chosen(), ['web']);
    });

    test('given middleware: kept when registered, else a ConfigException '
        'naming withSession() and the callback', () {
      final registry = MiddlewareRegistry()
        ..alias('known', const _Passthrough());
      expect(
        DashboardGate.middleware(
          registry,
          const ['known'],
          setup: 'withThing',
          authHint: 'Thing.auth',
        ),
        ['known'],
      );
      expect(
        () => DashboardGate.middleware(
          registry,
          const ['web'],
          setup: 'withThing',
          authHint: 'Thing.auth',
        ),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            allOf(
              startsWith('withThing(middleware: [web])'),
              contains('withSession()'),
              contains('Thing.auth((request) => ...)'),
            ),
          ),
        ),
      );
    });
  });
}

final class _Passthrough implements Middleware {
  const _Passthrough();
  @override
  Future<Response> handle(Request request, Next next) => next(request);
}
