import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `Application.serveBroadcastingOnly` (Blueprint #135, R3): what
/// `reverb:start` serves.
Application broadcastingApp() =>
    Application.configure(
          basePath: Directory.systemTemp.createTempSync('daravel_r3_').path,
        )
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'METRICS_ENABLED': 'true',
          'REVERB_APP_ID': '42',
          'REVERB_APP_KEY': 'key-a',
          'REVERB_APP_SECRET': 'secret-a',
        })
        .withRouting(
          api: (router) => router.get('/hello', (_) => 'hi'),
          apiPrefix: '',
        )
        .withBroadcasting(authMiddleware: const [])
        .create();

void main() {
  final engines = <ServerEngine>[];
  final apps = <Application>[];

  tearDown(() async {
    for (final engine in engines) {
      await engine.stop();
    }
    for (final app in apps) {
      await app.shutdown();
    }
    engines.clear();
    apps.clear();
  });

  Future<ServerEngine> serve(Application app) async {
    apps.add(app);
    await app.boot();
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
    engines.add(engine);
    return engine;
  }

  Future<int> status(ServerEngine engine, String method, String path) async {
    final client = HttpClient();
    try {
      final request = await client.openUrl(
        method,
        Uri.parse('http://127.0.0.1:${engine.port}$path'),
      );
      final response = await request.close();
      await response.drain<void>();
      return response.statusCode;
    } finally {
      client.close(force: true);
    }
  }

  test('serves the Pusher server under its path, probes and metrics, '
      'not the application routes', () async {
    final app = broadcastingApp()..serveBroadcastingOnly(path: '/ws/');
    expect(app.servesBroadcastingOnly, isTrue);
    final engine = await serve(app);

    expect(await status(engine, 'GET', '/hello'), 404);
    expect(await status(engine, 'GET', '/up'), 200);
    expect(await status(engine, 'GET', '/up/ready'), 200);
    expect(await status(engine, 'GET', '/metrics'), 200);
    // Unsigned: refused by the server, not unknown.
    expect(await status(engine, 'GET', '/ws/apps/42/channels'), 401);
    expect(await status(engine, 'GET', '/apps/42/channels'), 404);
    expect(await status(engine, 'POST', '/broadcasting/auth'), 404);

    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${engine.port}/ws/app/key-a?protocol=7',
    );
    addTearDown(socket.close);
    final first = await socket.first.timeout(const Duration(seconds: 5));
    expect(
      (jsonDecode(first as String) as Map<String, Object?>)['event'],
      'pusher:connection_established',
    );

    // The router still knows the application's routes (route:list).
    expect(app.router.routes.map((r) => r.path), contains('/hello'));
  });

  test('answers /broadcasting/auth only when asked', () async {
    final app = broadcastingApp()..serveBroadcastingOnly(auth: true);
    final engine = await serve(app);
    expect(await status(engine, 'POST', '/broadcasting/auth'), isNot(404));
    expect(await status(engine, 'GET', '/apps/42/channels'), 401);
  });

  test('withBroadcastApps makes the provider at boot, once', () async {
    var made = 0;
    final app =
        Application.configure(
              basePath: Directory.systemTemp.createTempSync('daravel_r3_').path,
            )
            .withEnv({
              'APP_ENV': 'testing',
              'DB_DATABASE': ':memory:',
              'EXTRA_APP_KEY': 'key-b',
            })
            .withBroadcasting()
            .withBroadcastApps((c) {
              made++;
              return ListAppProvider([
                BroadcastApp(
                  id: '7',
                  key: c.make<Env>().string('EXTRA_APP_KEY'),
                  secret: 'secret-b',
                ),
              ]);
            })
            .create();
    final engine = await serve(app);
    expect(await status(engine, 'GET', '/apps/7/channels'), 401);
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:${engine.port}/app/key-b?protocol=7',
    );
    addTearDown(socket.close);
    final first = await socket.first.timeout(const Duration(seconds: 5));
    expect(
      (jsonDecode(first as String) as Map<String, Object?>)['event'],
      'pusher:connection_established',
    );
    expect(made, 1);
  });

  test('is set before boot, with a path from the root', () async {
    expect(
      () => broadcastingApp().serveBroadcastingOnly(path: 'ws'),
      throwsArgumentError,
    );
    final app = broadcastingApp();
    apps.add(app);
    await app.boot();
    expect(app.serveBroadcastingOnly, throwsStateError);
  });

  test('restart() drains the server and serve() returns', () async {
    final app = broadcastingApp()..serveBroadcastingOnly();
    final started = Completer<ServerEngine>();
    final served = app.serve(
      options: const ServeOptions(
        host: '127.0.0.1',
        port: 0,
        handleSignals: false,
        shutdownTimeout: Duration(seconds: 5),
      ),
      onStarted: started.complete,
    );
    final engine = await started.future;
    expect(await status(engine, 'GET', '/up'), 200);
    expect(app.restartRequested, isFalse);
    await app.restart();
    await served.timeout(const Duration(seconds: 10));
    expect(app.restartRequested, isTrue);
  });

  test('--debug logs frames with signatures masked', () async {
    final lines = <String>[];
    final log = PusherFrameLog(lines.add);
    final subscribe = jsonEncode({
      'event': 'pusher:subscribe',
      'data': {
        'channel': 'presence-room',
        'auth': 'key-a:0123456789abcdef',
        'channel_data': '{"user_id":"1"}',
      },
    });
    log.frame('42', '1.2', 'in', subscribe);
    expect(lines.single, startsWith('[42] 1.2 <- '));
    expect(lines.single, isNot(contains('0123456789abcdef')));
    expect(lines.single, isNot(contains('user_id')));
    expect(lines.single, contains('presence-room'));

    // `data` as JSON text inside the frame, as servers send it.
    final established = jsonEncode({
      'event': 'pusher:connection_established',
      'data': jsonEncode({'socket_id': '1.2', 'activity_timeout': 30}),
    });
    expect(
      PusherFrameLog.mask(established),
      contains(r'\"socket_id\":\"1.2\"'),
    );
    expect(PusherFrameLog.mask('not json'), 'not json');

    // Secrets nothing should send are masked anywhere in a frame.
    final leaky = PusherFrameLog.mask(
      jsonEncode({
        'event': 'client-x',
        'data': jsonEncode({
          'nested': {'secret': 'top-secret-1', 'app_secret': 'top-secret-2'},
        }),
      }),
    );
    expect(leaky, isNot(contains('top-secret')));
    expect(leaky, contains('***'));
  }, tags: 'security');

  test('the default observer receives frames without copying them', () {
    // PusherObserver.frame is a no-op given the String the server already
    // holds: nothing is encoded for an observer that does not log.
    const observer = PusherObserver();
    const payload = '{"event":"pusher:ping","data":{}}';
    observer.frame('42', '1.2', 'in', payload);
    final seen = <Object?>[];
    PusherObservers([_Recorder(seen)]).frame('42', '1.2', 'out', payload);
    expect(identical(seen.single, payload), isTrue);
  });
}

final class _Recorder extends PusherObserver {
  _Recorder(this.seen);

  final List<Object?> seen;

  @override
  void frame(String app, String socketId, String direction, Object? payload) =>
      seen.add(payload);
}
