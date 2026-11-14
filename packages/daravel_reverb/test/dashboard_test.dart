import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_reverb/daravel_reverb.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

final String secretA = 'a' * 32;
final String secretB = 'b' * 32;

Application appWith({
  Map<String, String> env = const {},
  String dashboard = '/reverb',
  List<Object> middleware = const [],
}) =>
    Application.configure(
          basePath: Directory.systemTemp.createTempSync('reverb_dash_').path,
        )
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'METRICS_ENABLED': 'true',
          'QUEUE_SIGNAL_STORE': 'file',
          'REVERB_APP_ID': '42',
          'REVERB_APP_KEY': 'key-a',
          'REVERB_APP_SECRET': secretA,
          'REVERB_APPS': jsonEncode([
            {
              'app_id': '7',
              'key': 'key-b',
              'secret': secretB,
              'allowed_origins': ['b.example.com'],
              'max_connections': 5,
            },
          ]),
          ...env,
        })
        .withLogLevel(LogLevel.critical)
        .withBroadcasting(authMiddleware: const [])
        .withReverb(dashboard: dashboard, middleware: middleware)
        .create();

/// Stands in for `['auth', 'can:viewReverb']`: refuses everyone.
final class _Refuse implements Middleware {
  const _Refuse();

  @override
  Future<Response> handle(Request request, Next next) async =>
      Response(status: 403);
}

/// Stands in for a middleware that lets the operator through.
final class _Allow implements Middleware {
  const _Allow();

  @override
  Future<Response> handle(Request request, Next next) => next(request);
}

Future<Application> booted(Application app) async {
  await app.boot();
  addTearDown(app.shutdown);
  return app;
}

void main() {
  // APP_ENV=testing opens nothing: these tests let every request in. The
  // gate itself: test/dashboard_gate_test.dart.
  setUp(() => ReverbDashboard.auth((_) => true));
  tearDown(() => ReverbDashboard.auth(null));

  test('no routes with an empty dashboard path', () async {
    final app = await booted(appWith(dashboard: ''));
    final client = TestClient(app);
    expect((await client.get('/reverb')).status, 404);
    expect((await client.get('/reverb/api/stats')).status, 404);
    // The HTTP application does not watch for reverb:restart.
    expect(app.container.resolved<ReverbRestartWatcher>(), isNull);
  });

  test('the page: tabs, CSP nonce, hardening headers, no secret', () async {
    final app = await booted(appWith());
    final client = TestClient(app);
    final page = await client.get('/reverb');
    expect(page.status, 200);
    final csp = page.headers['content-security-policy']!;
    final nonce = RegExp(r"'nonce-([^']+)'").firstMatch(csp)![1]!;
    expect(page.body, contains('nonce="$nonce"'));
    expect(csp, contains("default-src 'none'"));
    expect(page.headers['x-frame-options'], 'DENY');
    expect(page.headers['cache-control'], 'no-store');
    expect(page.body, isNot(contains('src="http')));
    final again = await client.get('/reverb/workers');
    expect(again.status, 200);
    expect(again.headers['content-security-policy'], isNot(csp));
    expect((await client.get('/reverb/nope')).status, 404);
    expect(app.router.routes.map((r) => r.routeName), contains('reverb.index'));
  });

  test('api/stats is reverb:stats --json, api/apps has no secret', () async {
    final app = await booted(appWith());
    final client = TestClient(app);
    await app.run(() {
      final metrics = App.make<AppMetrics>()
        ..recordReverbConnection('42', 1)
        ..recordReverbSubscription('42', 'presence', 1)
        ..recordReverbMessage('42', 'in')
        ..recordReverbFanout('42', const Duration(microseconds: 300))
        ..recordReverbRejected('connection_quota', app: '7');
      return metrics;
    });
    final stats = (await client.get('/reverb/api/stats')).jsonMap;
    final a = (stats['apps']! as Map)['42']! as Map;
    expect(a['connections'], 1);
    expect(a['channels'], {'presence': 1});
    expect(a['messages_in'], 1);
    expect((a['fanout']! as Map)['count'], 1);
    expect(stats['rejected'], {'connection_quota': 1});
    expect(stats.keys, containsAll(['apps', 'workers', 'slow_clients']));

    final apps = await client.get('/reverb/api/apps');
    expect(apps.jsonMap['provider'], 'config');
    final list = apps.jsonMap['apps']! as List;
    expect(list.map((x) => (x! as Map)['id']), ['42', '7']);
    expect((list.first! as Map)['settings'], isTrue);
    expect(apps.body, isNot(contains(secretA)));
    expect(apps.body, isNot(contains(secretB)));
  }, tags: 'security');

  test('outside local, 403 without a callback or gate, mutations '
      'too', () async {
    ReverbDashboard.auth(null);
    final app = await booted(
      appWith(
        env: {
          'APP_ENV': 'production',
          'APP_KEY': 'base64:${base64.encode(List.filled(32, 3))}',
        },
      ),
    );
    final client = TestClient(app);
    for (final path in ['/reverb', '/reverb/api/stats', '/reverb/api/apps']) {
      final response = await client.get(path);
      expect(response.status, 403, reason: path);
      expect(response.body, isNot(contains(secretA)));
    }
    expect((await client.post('/reverb/api/restart')).status, 403);
    final signals = app.container.make<QueueManager>().signalStore!.store;
    expect(await signals.get(reverbRestartKey), isNull);
  }, tags: 'security');

  test('middleware runs before the gate and cannot open it', () async {
    final refused = await booted(appWith(middleware: [const _Refuse()]));
    expect((await TestClient(refused).get('/reverb')).status, 403);
    ReverbDashboard.auth(null);
    final passed = await booted(
      appWith(
        env: {
          'APP_ENV': 'production',
          'APP_KEY': 'base64:${base64.encode(List.filled(32, 3))}',
        },
        middleware: [const _Allow()],
      ),
    );
    expect((await TestClient(passed).get('/reverb')).status, 403);
  });

  test('api/restart puts the reverb:restart signal', () async {
    final app = await booted(appWith());
    final restarted = await TestClient(app).post('/reverb/api/restart');
    expect(restarted.status, 200);
    expect(restarted.jsonMap['restarting'], isTrue);
    final signals = app.container.make<QueueManager>().signalStore!.store;
    expect(await signals.get(reverbRestartKey), isA<int>());
  });

  test('api/stream sends a retry, updates, and ends when the server '
      'drains', () async {
    final app = await booted(appWith());
    final engine = ServerEngine(
      app,
      const ServeOptions(
        host: '127.0.0.1',
        port: 0,
        handleSignals: false,
        shutdownTimeout: Duration(seconds: 5),
      ),
      kernel: app.kernel,
      logger: Logger(minimumLevel: LogLevel.critical),
    );
    await engine.start();
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(
      Uri.parse('http://127.0.0.1:${engine.port}/reverb/api/stream'),
    )).close();
    expect(response.headers.contentType?.mimeType, 'text/event-stream');
    final text = StringBuffer();
    final ended = Completer<void>();
    response.transform(utf8.decoder).listen(text.write, onDone: ended.complete);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!'$text'.contains('event: update') &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect('$text', contains('retry: '));
    expect('$text', contains('event: update'));
    await engine.stop();
    await ended.future.timeout(const Duration(seconds: 10));
  });

  test('REVERB_METRICS_URL: the numbers of a reverb:start server', () async {
    // The WebSocket server, as reverb:start runs it.
    final ws = reverbServer(appWith)();
    await ws.boot();
    addTearDown(ws.shutdown);
    final engine = ServerEngine(
      ws,
      const ServeOptions(
        host: '127.0.0.1',
        port: 0,
        handleSignals: false,
        shutdownTimeout: Duration(seconds: 5),
      ),
      kernel: ws.kernel,
      logger: Logger(minimumLevel: LogLevel.critical),
    );
    await engine.start();
    addTearDown(engine.stop);
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${engine.port}/app/key-a?protocol=7',
    );
    addTearDown(socket.close);
    expect(
      await socket.first.timeout(const Duration(seconds: 5)),
      contains('connection_established'),
    );

    // The HTTP application's dashboard reads it.
    final dashboard = await booted(
      appWith(
        env: {'REVERB_METRICS_URL': 'http://127.0.0.1:${engine.port}/metrics'},
      ),
    );
    final stats = (await TestClient(dashboard).get('/reverb/api/stats'))
        .jsonMap;
    expect(((stats['apps']! as Map)['42']! as Map)['connections'], 1);
  });

  test('REVERB_METRICS_URL that does not answer: 503 "Metrics unreachable" '
      'within the timeout, the token and the URL never shown', () async {
    // Accepts connections and never answers.
    final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final held = <Socket>[];
    silent.listen(held.add);
    addTearDown(() async {
      for (final s in held) {
        s.destroy();
      }
      await silent.close();
    });
    const token = 'metrics-token-do-not-leak';
    final url =
        'http://scraper:pass-do-not-leak@127.0.0.1:${silent.port}/metrics';
    final app = await booted(
      appWith(env: {'REVERB_METRICS_URL': url, 'METRICS_TOKEN': token}),
    );
    final client = TestClient(app);
    final watch = Stopwatch()..start();
    final stats = await client.get('/reverb/api/stats');
    expect(watch.elapsed, lessThan(const Duration(seconds: 4)));
    expect(stats.status, 503);
    expect(stats.jsonMap['message'], startsWith('Metrics unreachable'));
    final page = await client.get('/reverb');
    for (final body in [stats.body, page.body]) {
      expect(body, isNot(contains(token)));
      expect(body, isNot(contains('pass-do-not-leak')));
    }
    final shown = jsonEncode(app.config.section<ReverbConfig>().toMap());
    expect(shown, isNot(contains('pass-do-not-leak')));
    expect(shown, contains('***@127.0.0.1'));
  }, tags: 'security');

  test('REVERB_METRICS_URL is read once a second, however many clients ask; '
      'a failure too', () async {
    var reads = 0;
    var fail = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((r) {
      reads++;
      r.response
        ..statusCode = fail ? 500 : 200
        ..write('# nothing\n')
        ..close();
    });
    freezeTime();
    final app = await booted(
      appWith(
        env: {'REVERB_METRICS_URL': 'http://127.0.0.1:${server.port}/metrics'},
      ),
    );
    final first = TestClient(app);
    final second = TestClient(app);
    for (var tick = 1; tick <= 2; tick++) {
      for (final client in [first, second]) {
        expect((await client.get('/reverb/api/stats')).status, 200);
      }
      expect(reads, tick, reason: 'one read a second');
      travel(const Duration(seconds: 1));
    }
    // A failing read is kept for its second as well.
    fail = true;
    for (final client in [first, second]) {
      expect((await client.get('/reverb/api/stats')).status, 503);
    }
    expect(reads, 3);
  });

  test('REVERB_METRICS_URL: a redirect is not followed, so the token goes '
      'to no other host', () async {
    var redirected = 0;
    final elsewhere = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(elsewhere.close);
    elsewhere.listen((r) {
      redirected++;
      r.response.close();
    });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((r) {
      r.response
        ..statusCode = 302
        ..headers.set('location', 'http://127.0.0.1:${elsewhere.port}/steal')
        ..close();
    });
    final app = await booted(
      appWith(
        env: {
          'REVERB_METRICS_URL': 'http://127.0.0.1:${server.port}/metrics',
          'METRICS_TOKEN': 'metrics-token',
        },
      ),
    );
    final stats = await TestClient(app).get('/reverb/api/stats');
    expect(stats.status, 503);
    expect(stats.jsonMap['message'], contains('302'));
    expect(redirected, 0);
  }, tags: 'security');

  test('REVERB_METRICS_URL is http(s) only', () {
    final env = Env.fromMap({'REVERB_METRICS_URL': 'file:///etc/passwd'});
    final config = ConfigRepository()
      ..register<ReverbConfig>(ReverbConfig.fromEnv(env))
      ..register<BroadcastConfig>(BroadcastConfig.fromEnv(env));
    expect(
      ReverbConfig.check(env, config).where((i) => i.isError).single.message,
      contains('REVERB_METRICS_URL'),
    );
  }, tags: 'security');
}
