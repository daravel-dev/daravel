import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_reverb/daravel_reverb.dart';
import 'package:test/test.dart';

const _key = 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
final String _secret = 's' * 32;

/// Lets a request through untouched: middleware that is not
/// authorization, like `throttle`.
final class _Passthrough implements Middleware {
  const _Passthrough();
  @override
  Future<Response> handle(Request request, Next next) => next(request);
}

/// Who may open the Reverb dashboard: `APP_ENV=local`; otherwise
/// `ReverbDashboard.auth`, else the `viewReverb` gate; never middleware
/// alone, never `APP_ENV=testing`. Every `reverb.*` route, as the router
/// lists it, answers the same, and no answer carries an application secret.
void main() {
  late Directory dir;
  Application? app;

  setUp(() => dir = Directory.systemTemp.createTempSync('reverb_gate_'));
  tearDown(() async {
    ReverbDashboard.auth(null);
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
          'METRICS_ENABLED': 'true',
          'QUEUE_SIGNAL_STORE': 'file',
          'REVERB_APP_ID': '42',
          'REVERB_APP_KEY': 'key-a',
          'REVERB_APP_SECRET': _secret,
        })
        .withLogLevel(LogLevel.critical)
        .withMiddleware((m) => m.alias('pass', const _Passthrough()))
        .withBroadcasting(authMiddleware: const [])
        .withReverb(middleware: middleware)
        .create();
    app = booted;
    await booted.boot();
    if (gate != null) {
      await booted.run(() async => Gate.define('viewReverb', gate));
    }
    return booted;
  }

  /// Every dashboard route from the router, as a request (the stream left
  /// out: it does not end; it shares the guard and is listed).
  List<Request> dashboardRequests(Application app) {
    final routes = [
      for (final route in app.router.routes)
        if (route.routeName?.startsWith('reverb.') ?? false) route,
    ];
    expect(routes.map((r) => r.routeName).toSet(), {
      'reverb.stats',
      'reverb.apps',
      'reverb.stream',
      'reverb.restart',
      'reverb.index',
      'reverb.view',
    });
    return [
      for (final route in routes)
        if (route.routeName != 'reverb.stream')
          Request.fake(
            method: route.methods.first,
            path: route.path.replaceFirst('{view}', 'apps'),
          ),
    ];
  }

  Future<List<int>> statuses(
    Application app, {
    Map<String, String> headers = const {},
  }) async {
    final out = <int>[];
    for (final request in dashboardRequests(app)) {
      final response = await app.handle(
        Request.fake(
          method: request.method,
          path: request.path,
          headers: headers,
        ),
      );
      expect(await response.bodyText(), isNot(contains(_secret)));
      out.add(response.status);
    }
    return out;
  }

  test('production with middleware that is not authorization: 403 on '
      'every route, the restart signal untouched', () async {
    final booted = await boot(middleware: ['throttle:60']);
    expect(await statuses(booted), everyElement(403));
    final signals = booted.container.make<QueueManager>().signalStore!.store;
    expect(await signals.get(reverbRestartKey), isNull);
    await app!.shutdown();
    expect(await statuses(await boot(middleware: ['pass'])), everyElement(403));
  });

  test('testing is closed; local is open', () async {
    expect(await statuses(await boot(env: 'testing')), everyElement(403));
    await app!.shutdown();
    expect(await statuses(await boot(env: 'local')), everyElement(200));
  });

  test('the viewReverb gate decides; the callback before it', () async {
    expect(
      await statuses(await boot(gate: (Authenticatable? user, _) => true)),
      everyElement(200),
    );
    await app!.shutdown();
    ReverbDashboard.auth((request) => request.header('x-ops') == 'yes');
    final booted = await boot(gate: (Authenticatable? user, _) => true);
    expect(await statuses(booted), everyElement(403));
    expect(
      await statuses(booted, headers: const {'x-ops': 'yes'}),
      everyElement(200),
    );
  });

  test('a callback that throws is a 403', () async {
    ReverbDashboard.auth((_) => throw StateError('broken'));
    expect(await statuses(await boot()), everyElement(403));
  });

  test('middleware the application does not register stops the boot', () {
    expect(
      boot(middleware: ['web']),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          allOf(contains('withSession()'), contains('ReverbDashboard.auth')),
        ),
      ),
    );
  });

  test('api/apps lists keys, never secrets', () async {
    final booted = await boot(env: 'local');
    final response = await booted.handle(
      Request.fake(path: '/reverb/api/apps'),
    );
    final body = await response.bodyText();
    expect(body, contains('key-a'));
    expect(body, isNot(contains(_secret)));
    expect(jsonDecode(body), isA<Map<String, Object?>>());
  });
}
