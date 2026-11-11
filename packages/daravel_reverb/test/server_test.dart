import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_reverb/daravel_reverb.dart';
import 'package:test/test.dart';

final String secretA = 'a' * 32;
final String secretB = 'b' * 32;
final String base = Directory.systemTemp
    .createTempSync('daravel_reverb_server_')
    .path;

/// The application `reverb:start` is given: settings app `42`/`key-a`,
/// and `7`/`key-b` from `REVERB_APPS` (one connection, two messages).
Application reverbApp() => Application.configure(basePath: base)
    .withEnv({
      'APP_ENV': 'testing',
      'DB_DATABASE': ':memory:',
      'QUEUE_SIGNAL_STORE': 'file',
      'REVERB_APP_ID': '42',
      'REVERB_APP_KEY': 'key-a',
      'REVERB_APP_SECRET': secretA,
      'REVERB_DRAIN_SPREAD': '1500ms',
      'REVERB_APPS': jsonEncode([
        {
          'app_id': '7',
          'key': 'key-b',
          'secret': secretB,
          'max_connections': 1,
          'rate_limiting': {
            'enabled': true,
            'max_attempts': 2,
            'decay_seconds': 60,
            'terminate_on_limit': true,
          },
        },
      ]),
    })
    .withLogLevel(LogLevel.critical)
    .withRouting(api: (router) => router.get('/hello', (_) => 'hi'))
    .withBroadcasting(authMiddleware: const [])
    .withReverb()
    .create();

const BroadcastApp appB = BroadcastApp(id: '7', key: 'key-b', secret: '');

/// One Pusher client: its frames as they come.
final class Client {
  Client._(this.socket) {
    socket.listen(
      (frame) =>
          frames.add(jsonDecode(frame as String) as Map<String, Object?>),
      onDone: () => closed.complete(socket.closeCode),
    );
  }

  static Future<Client> connect(int port, String key) async => Client._(
    await WebSocket.connect('ws://127.0.0.1:$port/app/$key?protocol=7'),
  );

  final WebSocket socket;
  final List<Map<String, Object?>> frames = [];
  final Completer<int?> closed = Completer();

  void send(Map<String, Object?> frame) => socket.add(jsonEncode(frame));

  Future<Map<String, Object?>> next(String event) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final index = frames.indexWhere((f) => f['event'] == event);
      if (index >= 0) {
        return frames.removeAt(index);
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('No $event; got $frames');
  }

  int? errorCode(Map<String, Object?> frame) {
    final data = frame['data'];
    final map = data is String ? jsonDecode(data) : data;
    return (map! as Map<String, Object?>)['code'] as int?;
  }
}

void main() {
  late Application app;
  late Future<void> served;
  late int port;
  final clients = <Client>[];

  setUp(() async {
    app = reverbServer(reverbApp)();
    final started = Completer<ServerEngine>();
    served = app.serve(
      options: const ServeOptions(
        host: '127.0.0.1',
        port: 0,
        handleSignals: false,
        shutdownTimeout: Duration(seconds: 5),
      ),
      onStarted: started.complete,
    );
    port = (await started.future).port!;
  });

  tearDown(() async {
    for (final client in clients) {
      await client.socket.close();
    }
    clients.clear();
    await app.engine?.stop();
    await served;
  });

  Future<Client> connect(String key) async {
    final client = await Client.connect(port, key);
    clients.add(client);
    return client;
  }

  test('serves broadcasting only, both apps', () async {
    final client = HttpClient();
    addTearDown(client.close);
    Future<int> status(String path) async {
      final response = await (await client.getUrl(
        Uri.parse('http://127.0.0.1:$port$path'),
      )).close();
      await response.drain<void>();
      return response.statusCode;
    }

    expect(await status('/api/hello'), 404);
    expect(await status('/up'), 200);
    await (await connect('key-a')).next('pusher:connection_established');
    await (await connect('key-b')).next('pusher:connection_established');
    expect(app.container.resolved<ReverbRestartWatcher>()?.watching, isTrue);
  });

  test('4001 for an unknown key', () async {
    final client = await connect('key-x');
    final error = await client.next('pusher:error');
    expect(client.errorCode(error), 4001);
  });

  test('4004 past an app connection quota', () async {
    await (await connect('key-b')).next('pusher:connection_established');
    final second = await connect('key-b');
    expect(second.errorCode(await second.next('pusher:error')), 4004);
    // The other app is not affected.
    await (await connect('key-a')).next('pusher:connection_established');
  });

  test('4301 past an app rate limit, closed when it terminates', () async {
    final client = await connect('key-b');
    await client.next('pusher:connection_established');
    for (var i = 0; i < 3; i++) {
      client.send({
        'event': 'pusher:subscribe',
        'data': {'channel': 'news-$i'},
      });
    }
    expect(client.errorCode(await client.next('pusher:error')), 4301);
    expect(
      await client.closed.future.timeout(const Duration(seconds: 5)),
      4301,
    );
  });

  test('the apps channels are apart', () async {
    final a = await connect('key-a');
    final b = await connect('key-b');
    for (final client in [a, b]) {
      await client.next('pusher:connection_established');
      client.send({
        'event': 'pusher:subscribe',
        'data': {'channel': 'news'},
      });
      await client.next('pusher_internal:subscription_succeeded');
    }
    final body = jsonEncode({
      'name': 'headline',
      'channel': 'news',
      'data': '{"for":"b"}',
    });
    const path = '/apps/7/events';
    final query = PusherSignature.signRequest(
      key: appB.key,
      secret: secretB,
      method: 'POST',
      path: path,
      body: body,
    );
    final http = HttpClient();
    addTearDown(http.close);
    final request = await http.postUrl(
      Uri.http('127.0.0.1:$port', path, query),
    );
    request.headers.contentType = ContentType.json;
    request.write(body);
    final response = await request.close();
    await response.drain<void>();
    expect(response.statusCode, 200);
    expect((await b.next('headline'))['channel'], 'news');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(a.frames.where((f) => f['event'] == 'headline'), isEmpty);

    // Signed with app 42's secret for app 7: refused.
    final wrong = PusherSignature.signRequest(
      key: 'key-a',
      secret: secretA,
      method: 'POST',
      path: path,
      body: body,
    );
    final refused = await http.postUrl(
      Uri.http('127.0.0.1:$port', path, wrong),
    );
    refused.headers.contentType = ContentType.json;
    refused.write(body);
    final answer = await refused.close();
    await answer.drain<void>();
    expect(answer.statusCode, 401);
  });

  test('reverb:restart drains the connections over the spread and ends '
      'serve()', () async {
    final opened = <Client>[];
    for (var i = 0; i < 20; i++) {
      final client = await connect('key-a');
      await client.next('pusher:connection_established');
      opened.add(client);
    }
    // As the CLI does: another application of the same project.
    final cli = reverbApp();
    await cli.boot();
    final watch = Stopwatch()..start();
    expect(await requestReverbRestart(cli), isTrue);
    await cli.shutdown();

    final closedAt = await Future.wait([
      for (final client in opened)
        client.closed.future.then((_) => watch.elapsedMilliseconds),
    ]).timeout(const Duration(seconds: 15));
    await served.timeout(const Duration(seconds: 15));
    expect(app.restartRequested, isTrue);
    closedAt.sort();
    // Spread over REVERB_DRAIN_SPREAD (1.5 s), not all at once.
    expect(closedAt.last - closedAt.first, greaterThan(500));
  }, timeout: const Timeout(Duration(minutes: 1)));
}
