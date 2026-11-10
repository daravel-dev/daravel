import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_reverb/daravel_reverb.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import '../bootstrap/app.dart';

final String secret = 's' * 40;
final String partnerSecret = 'p' * 40;

Map<String, String> env([Map<String, String> extra = const {}]) => {
  'APP_ENV': 'testing',
  'DB_DATABASE': ':memory:',
  'METRICS_ENABLED': 'true',
  'QUEUE_SIGNAL_STORE': 'file',
  'REVERB_APP_ID': 'demo',
  'REVERB_APP_KEY': 'demo-key',
  'REVERB_APP_SECRET': secret,
  'REVERB_ENCRYPTION_MASTER_KEY_BASE64': base64.encode(List.filled(32, 7)),
  'REVERB_APPS': jsonEncode([
    {
      'app_id': 'partner',
      'key': 'partner-key',
      'secret': partnerSecret,
      'allowed_origins': ['localhost'],
    },
  ]),
  'LOG_LEVEL': 'emergency',
  ...extra,
};

/// A Pusher client of [key] on [port]: its frames as they come.
final class Client {
  Client._(this.socket) {
    socket.listen(
      (frame) =>
          frames.add(jsonDecode(frame as String) as Map<String, Object?>),
    );
  }

  static Future<Client> connect(int port, String key) async => Client._(
    await WebSocket.connect(
      'ws://127.0.0.1:$port/app/$key?protocol=7',
      headers: {'Origin': 'http://localhost'},
    ),
  );

  final WebSocket socket;
  final List<Map<String, Object?>> frames = [];

  Future<Map<String, Object?>> next(String event) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final i = frames.indexWhere((f) => f['event'] == event);
      if (i >= 0) {
        return frames.removeAt(i);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('No $event; got $frames');
  }

  Future<void> subscribe(String channel) async {
    await next('pusher:connection_established');
    socket.add(
      jsonEncode({
        'event': 'pusher:subscribe',
        'data': {'channel': channel},
      }),
    );
    await next('pusher_internal:subscription_succeeded');
  }
}

void main() {
  late Application ws;
  late ServerEngine engine;
  late Application app;
  late TestClient client;
  final sockets = <Client>[];

  setUp(() async {
    // The WebSocket server, as `reverb:start` serves it.
    ws = reverbServer(() => createApp(env: env()))();
    await ws.boot();
    engine = ServerEngine(
      ws,
      const ServeOptions(
        host: '127.0.0.1',
        port: 0,
        handleSignals: false,
        shutdownTimeout: Duration(seconds: 5),
      ),
      kernel: ws.kernel,
      logger: Logger(minimumLevel: LogLevel.emergency),
    );
    await engine.start();
    // The HTTP application, publishing to it through its HTTP API.
    app = createApp(
      env: env({
        'BROADCAST_CONNECTION': 'reverb',
        'REVERB_HOST': '127.0.0.1',
        'REVERB_PORT': '${engine.port}',
        'REVERB_SCHEME': 'http',
        'REVERB_METRICS_URL': 'http://127.0.0.1:${engine.port}/metrics',
      }),
    );
    await app.boot();
    client = TestClient(app);
  });

  tearDown(() async {
    for (final s in sockets) {
      await s.socket.close();
    }
    sockets.clear();
    await app.shutdown();
    await engine.stop();
    await ws.shutdown();
  });

  Future<Client> connect(String key) async {
    final c = await Client.connect(engine.port!, key);
    sockets.add(c);
    return c;
  }

  test('the HTTP application broadcasts through the WebSocket server; '
      'the partner application hears nothing of it', () async {
    final demo = await connect('demo-key');
    final partner = await connect('partner-key');
    await demo.subscribe('news');
    await partner.subscribe('news');
    expect((await client.post('/demo/announce')).status, 200);
    final heard = await demo.next('announcement');
    expect(jsonDecode(heard['data']! as String), {
      'text': 'Hello from the HTTP application',
    });
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(partner.frames.where((f) => f['event'] == 'announcement'), isEmpty);
  });

  test('presence members come from the HTTP application', () async {
    final answer = await client.post(
      '/broadcasting/auth',
      headers: {'Authorization': 'Bearer user-2'},
      form: {'socket_id': '1234.5678', 'channel_name': 'presence-chat.lobby'},
    );
    expect(answer.status, 200);
    final data = jsonDecode(answer.jsonMap['channel_data']! as String) as Map;
    expect(data['user_info'], {'id': 2, 'name': 'Budi'});
    expect(answer.jsonMap['auth'], startsWith('demo-key:'));
    final refused = await client.post(
      '/broadcasting/auth',
      form: {'socket_id': '1234.5678', 'channel_name': 'presence-chat.lobby'},
    );
    expect(refused.status, anyOf(401, 403));
  });

  test('the dashboard: for the viewReverb gate only, with the WebSocket '
      "server's numbers", () async {
    await (await connect('demo-key')).subscribe('news');
    expect((await client.get('/reverb')).status, 401);
    expect(
      (await client.get(
        '/reverb',
        headers: {'Authorization': 'Bearer user-2'},
      )).status,
      403,
    );
    final admin = {'Authorization': 'Bearer user-1'};
    expect((await client.get('/reverb', headers: admin)).status, 200);
    final stats = (await client.get(
      '/reverb/api/stats',
      headers: admin,
    )).jsonMap;
    final demo = (stats['apps']! as Map)['demo']! as Map;
    expect(demo['connections'], 1);
    expect(demo['channels'], {'public': 1});
    final apps = await client.get('/reverb/api/apps', headers: admin);
    expect((apps.jsonMap['apps']! as List).map((a) => (a! as Map)['id']), [
      'demo',
      'partner',
    ]);
    expect(apps.body, isNot(contains(secret)));
    expect(apps.body, isNot(contains(partnerSecret)));
  });
}
