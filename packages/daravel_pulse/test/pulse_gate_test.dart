import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:daravel_pulse/daravel_pulse.dart';
import 'package:test/test.dart';

/// Lets a request through untouched: middleware that is not
/// authorization, like `throttle`.
final class _Passthrough implements Middleware {
  const _Passthrough();
  @override
  Future<Response> handle(Request request, Next next) => next(request);
}

/// Names the isolate that answered.
final class _Isolate implements Middleware {
  const _Isolate();
  @override
  Future<Response> handle(Request request, Next next) async {
    final response = await next(request);
    response.headers.set('x-isolate', Isolate.current.debugName ?? '');
    return response;
  }
}

const _key = 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

/// Top-level, sendable to worker isolates: Pulse.auth set in createApp.
Application supervisedPulse() {
  Pulse.auth((request) => request.header('x-pulse') == 'let-me-in');
  return Application.configure(basePath: Directory.systemTemp.path)
      .withEnv(const {
        'APP_ENV': 'production',
        'APP_KEY': _key,
        'DB_DATABASE': ':memory:',
        'LOG_LEVEL': 'emergency',
      })
      .withMiddleware((m) => m.use(const [_Isolate()]))
      .withPulse()
      .create();
}

/// Who may open the Pulse dashboard: `APP_ENV=local`; otherwise
/// `Pulse.auth`, else the `viewPulse` gate (laravel/pulse v1.10.0); never
/// middleware alone, never `APP_ENV=testing`. Every dashboard route, as
/// the router lists it, answers the same.
void main() {
  late Directory dir;
  Application? app;

  setUp(() => dir = Directory.systemTemp.createTempSync('pulse_gate_'));
  tearDown(() async {
    Pulse.auth(null);
    await app?.shutdown();
    app = null;
    dir.deleteSync(recursive: true);
  });

  Future<Application> boot({
    String env = 'production',
    List<Object>? middleware,
    GateCallback? gate,
  }) async {
    final booted = Application.configure(basePath: dir.path)
        .withEnv({
          'APP_ENV': env,
          'APP_KEY': _key,
          'DB_DATABASE': ':memory:',
          'LOG_LEVEL': 'emergency',
        })
        .withMiddleware((m) => m.alias('pass', const _Passthrough()))
        .withPulse(middleware: middleware)
        .create();
    app = booted;
    await booted.boot();
    if (gate != null) {
      await booted.run(() async => Gate.define('viewPulse', gate));
    }
    return booted;
  }

  /// Every route of the dashboard: the page and its API, from the router.
  List<String> dashboardPaths(Application app) {
    final paths = [
      for (final route in app.router.routes)
        if (route.path == '/pulse' || route.path.startsWith('/pulse/'))
          route.path,
    ];
    expect(paths, ['/pulse', '/pulse/api/stats']);
    return paths;
  }

  Future<List<int>> statuses(
    Application app, {
    Map<String, String> headers = const {},
  }) async => [
    for (final path in dashboardPaths(app))
      (await app.handle(Request.fake(path: path, headers: headers))).status,
  ];

  test('production with middleware that is not authorization (case 2): '
      '403 on every route', () async {
    expect(await statuses(await boot(middleware: ['throttle:60'])), [403, 403]);
    await app!.shutdown();
    expect(await statuses(await boot(middleware: ['pass'])), [403, 403]);
  });

  test('production without middleware (case 4): 403', () async {
    expect(await statuses(await boot()), [403, 403]);
  });

  test('testing is closed too (case 3); local is open (case 5)', () async {
    expect(await statuses(await boot(env: 'testing')), [403, 403]);
    await app!.shutdown();
    expect(await statuses(await boot(env: 'local')), [200, 200]);
  });

  test('the viewPulse gate decides outside local; the installer snippet of '
      'earlier versions still works the same (case 1)', () async {
    expect(
      await statuses(await boot(gate: (Authenticatable? user, _) => true)),
      [200, 200],
    );
    await app!.shutdown();
    expect(
      await statuses(await boot(gate: (Authenticatable? user, _) => false)),
      [403, 403],
    );
    await app!.shutdown();
    // `can:viewPulse`: the gate decides there and again here.
    expect(
      await statuses(
        await boot(
          middleware: ['can:viewPulse'],
          gate: (Authenticatable? user, _) => true,
        ),
      ),
      [200, 200],
    );
    await app!.shutdown();
    // The installer's old snippet still boots: both aliases are core's.
    await boot(
      middleware: ['auth', 'can:viewPulse'],
      gate: (Authenticatable? user, _) => true,
    );
  });

  test('Pulse.auth decides before the gate', () async {
    Pulse.auth((request) => request.header('x-pulse') == 'let-me-in');
    final booted = await boot(gate: (Authenticatable? user, _) => true);
    expect(await statuses(booted), [403, 403]);
    expect(await statuses(booted, headers: const {'x-pulse': 'let-me-in'}), [
      200,
      200,
    ]);
  });

  test('a callback or gate that throws is a 403, logged', () async {
    Pulse.auth((_) => throw StateError('broken'));
    expect(await statuses(await boot()), [403, 403]);
    await app!.shutdown();
    Pulse.auth(null);
    expect(
      await statuses(
        await boot(gate: (Authenticatable? user, _) => throw StateError('x')),
      ),
      [403, 403],
    );
  });

  test('middleware the application does not register stops the boot; '
      'without sessions the default boots', () async {
    await expectLater(
      boot(middleware: ['web']),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          allOf(contains('withSession()'), contains('Pulse.auth')),
        ),
      ),
    );
    app = null;
    expect(await statuses(await boot()), [403, 403]);
  });

  test('Pulse.auth set in createApp holds in every worker isolate', () async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final supervisor = Supervisor(
      supervisedPulse,
      ServeOptions(
        host: '127.0.0.1',
        port: port,
        isolates: 2,
        handleSignals: false,
        shutdownTimeout: const Duration(seconds: 5),
        readyTimeout: const Duration(seconds: 60),
      ),
      logger: Logger(minimumLevel: LogLevel.warning),
    );
    await supervisor.start();
    addTearDown(supervisor.stop);
    final seen = <String, Set<int>>{};
    for (var i = 0; i < 200 && seen.length < 2; i++) {
      // A connection per request, so that both isolates take some.
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('http://127.0.0.1:$port/pulse/api/stats'),
        );
        request.headers.set('x-pulse', 'let-me-in');
        final response = await request.close();
        await utf8.decodeStream(response);
        seen
            .putIfAbsent(response.headers.value('x-isolate') ?? '', () => {})
            .add(response.statusCode);
      } finally {
        client.close(force: true);
      }
    }
    expect(seen.keys, hasLength(2));
    expect(seen.values, everyElement({200}));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
