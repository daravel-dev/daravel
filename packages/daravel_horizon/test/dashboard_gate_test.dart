import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:daravel_session/daravel_session.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// Lets a request through untouched: middleware that is not
/// authorization, like `throttle`.
final class _Passthrough implements Middleware {
  const _Passthrough();
  @override
  Future<Response> handle(Request request, Next next) => next(request);
}

Application gateApp([Map<String, String> env = const {}]) =>
    _gateApp(env, const []);

Application _gateApp(
  Map<String, String> env,
  List<Object> middleware, {
  LogLevel level = LogLevel.critical,
}) =>
    Application.configure(
          basePath: env['BASE_PATH'] ?? Directory.systemTemp.path,
        )
        .withEnv({
          'APP_ENV': 'production',
          'APP_KEY': 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
          'DB_DATABASE': ':memory:',
          'QUEUE_CONNECTION': 'database',
          'HORIZON_ALLOW_SQLITE': 'true',
          ...env,
        })
        .withLogLevel(level)
        .withMiddleware((m) => m.alias('pass', const _Passthrough()))
        .withMigrations(const [CreateJobsTable()])
        .withHorizon(createApp: gateApp, middleware: middleware)
        .create();

void main() {
  late Directory base;
  Application? app;

  setUp(() {
    base = Directory.systemTemp.createTempSync('horizon_gate_');
  });

  tearDown(() async {
    HorizonDashboard.auth(null);
    await app?.shutdown();
    app = null;
    base.deleteSync(recursive: true);
  });

  Future<TestClient> boot({
    String env = 'production',
    List<Object> middleware = const [],
    void Function()? gate,
    bool logged = false,
  }) async {
    final booted = _gateApp(
      {
        'APP_ENV': env,
        'BASE_PATH': base.path,
        if (logged) 'LOG_CHANNEL': 'null',
      },
      middleware,
      level: logged ? LogLevel.error : LogLevel.critical,
    );
    app = booted;
    await booted.boot();
    await booted.run(() => App.make<Migrator>().run());
    if (gate != null) {
      await booted.run(() async => gate());
    }
    return TestClient(booted);
  }

  group('the dashboard gate', () {
    test('middleware that does not authorize opens nothing', () async {
      final client = await boot(middleware: const ['pass']);
      (await client.get('/horizon/api/stats')).assertStatus(403);
      (await client.get('/horizon')).assertStatus(403);
    });

    test('only local passes without a gate: testing does not', () async {
      final local = await boot(env: 'local');
      (await local.get('/horizon/api/stats')).assertOk();
      await app!.shutdown();
      app = null;

      for (final name in ['testing', 'staging', 'production']) {
        final client = await boot(env: name);
        (await client.get('/horizon/api/stats')).assertStatus(403);
        await app!.shutdown();
        app = null;
      }
    });

    test('the viewHorizon gate decides outside local', () async {
      var allow = false;
      final client = await boot(
        gate: () =>
            Gate.define('viewHorizon', (Authenticatable? user, _) => allow),
      );
      (await client.get('/horizon/api/stats')).assertStatus(403);
      allow = true;
      (await client.get('/horizon/api/stats')).assertOk();
      (await client.get('/horizon')).assertOk();
    });

    test('HorizonDashboard.auth decides when it is given', () async {
      var allow = true;
      HorizonDashboard.auth((Request request) => allow);
      final client = await boot(
        // The gate allows; the callback still decides.
        gate: () => Gate.define('viewHorizon', (Authenticatable? u, _) => true),
      );
      (await client.get('/horizon/api/stats')).assertOk();
      allow = false;
      (await client.get('/horizon/api/stats')).assertStatus(403);
    });

    test('the callback gets the request', () async {
      HorizonDashboard.auth(
        (Request request) async => request.header('x-key') == 'open',
      );
      final client = await boot();
      (await client.get('/horizon/api/stats')).assertStatus(403);
      (await client.get(
        '/horizon/api/stats',
        headers: {'x-key': 'open'},
      )).assertOk();
    });

    test('a throwing callback denies and is logged', () async {
      HorizonDashboard.auth((Request request) => throw StateError('boom'));
      final client = await boot(env: 'staging', logged: true);
      final logs = await app!.run(() async => Log.spy());
      (await client.get('/horizon/api/stats')).assertStatus(403);
      logs.assertLogged(LogLevel.error, 'Horizon dashboard authorization');
      // The process still answers.
      HorizonDashboard.auth((Request request) => true);
      (await client.get('/horizon/api/stats')).assertOk();
    });

    test('a throwing gate denies and is logged', () async {
      final client = await boot(
        gate: () => Gate.define(
          'viewHorizon',
          (Authenticatable? user, _) => throw StateError('boom'),
        ),
        logged: true,
      );
      final logs = await app!.run(() async => Log.spy());
      (await client.get('/horizon/api/stats')).assertStatus(403);
      logs.assertLogged(LogLevel.error, 'Horizon dashboard authorization');
    });

    test('every dashboard route is behind the gate', () async {
      final client = await boot(middleware: const ['pass']);
      final routes = app!.container
          .make<Router>()
          .routes
          .where((r) => r.routeName?.startsWith('horizon.') ?? false)
          .toList();
      // Counted from the route table: a new route cannot miss the gate.
      expect(routes.length, greaterThanOrEqualTo(20));
      expect(
        routes.where((r) => !r.methods.contains('GET')),
        isNotEmpty,
        reason: 'the mutations (retry, monitoring) are counted too',
      );
      for (final route in routes) {
        final uri = route.path.replaceAll(RegExp(r'\{[^}]+\}'), 'x');
        for (final method in route.methods.where((m) => m != 'HEAD')) {
          final response = await client.send(method, uri);
          expect(
            response.status,
            403,
            reason: '$method $uri (${route.routeName})',
          );
        }
      }
    });
  });

  group('the default middleware', () {
    ApplicationBuilder builder(String env) =>
        Application.configure(basePath: base.path)
            .withEnv({
              'APP_ENV': env,
              'APP_KEY': 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
              'DB_DATABASE': ':memory:',
              'QUEUE_CONNECTION': 'database',
              'HORIZON_ALLOW_SQLITE': 'true',
              'SESSION_DRIVER': 'array',
            })
            .withLogLevel(LogLevel.critical)
            .withMigrations(const [CreateJobsTable()]);

    test('without sessions: nothing, the boot works, and production is '
        'closed', () async {
      final booted = builder('production')
          .withHorizon(createApp: gateApp)
          .create();
      app = booted;
      await booted.boot();
      expect(booted.container.make<HorizonRoutes>().middleware, isEmpty);
      final client = TestClient(booted);
      (await client.get('/horizon')).assertStatus(403);
      (await client.post('/horizon/api/jobs/retry-all')).assertStatus(403);
    });

    test(
      'with sessions: the web group, whose session the gate reads',
      () async {
        final booted = builder('production')
            .withSession()
            .withRouting(
              web: (r) => r.group((g) {
                g.get('/in', (Request request) {
                  request.session.put('horizon', true);
                  return 'in';
                });
              }, middleware: const ['web']),
            )
            .withHorizon(createApp: gateApp)
            .create();
        app = booted;
        await booted.boot();
        await booted.run(
          () async => Gate.define(
            'viewHorizon',
            (Authenticatable? user, _) =>
                App.make<Request>().session.get<bool>('horizon') ?? false,
          ),
        );
        expect(booted.container.make<HorizonRoutes>().middleware, ['web']);
        final client = TestClient(booted, cookieJar: CookieJar());
        (await client.get('/horizon/api/masters')).assertStatus(403);
        (await client.get('/in')).assertOk();
        (await client.get('/horizon/api/masters')).assertOk();
      },
    );

    test('middleware given that the application lacks stops the boot '
        'clearly', () async {
      final booted = builder('production')
          .withHorizon(createApp: gateApp, middleware: const ['web', 'auth'])
          .create();
      await expectLater(
        booted.boot(),
        throwsA(
          isA<ConfigException>()
              .having((e) => e.message, 'message', contains('withSession()'))
              .having(
                (e) => e.message,
                'message',
                contains('HorizonDashboard.auth'),
              ),
        ),
      );
      await booted.shutdown();
    });
  });
}
