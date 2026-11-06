import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Two Pusher applications on one server (Blueprint #135, R2): `a` is the
/// one of the `REVERB_APP_*` settings, `b` comes from the provider only.
const BroadcastApp appA = BroadcastApp(id: '42', key: 'key-a', secret: 'sec-a');
const BroadcastApp appB = BroadcastApp(
  id: '7',
  key: 'key-b',
  secret: 'sec-b',
  maxConnections: 1,
);

void main() {
  late Application app;
  late ServerEngine engine;

  setUp(() async {
    app =
        Application.configure(
              basePath: Directory.systemTemp.createTempSync('daravel_r2_').path,
            )
            .withEnv({
              'APP_ENV': 'testing',
              'DB_DATABASE': ':memory:',
              'REVERB_APP_ID': appA.id,
              'REVERB_APP_KEY': appA.key,
              'REVERB_APP_SECRET': appA.secret,
            })
            .withBroadcasting(apps: ListAppProvider([appA, appB]))
            .create();
    await app.boot();
    engine = ServerEngine(
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
  });

  tearDown(() async {
    await engine.stop();
    await app.shutdown();
  });

  String url(String key) => 'ws://127.0.0.1:${engine.port}/app/$key?protocol=7';

  Future<HttpClientResponse> api(
    BroadcastApp app,
    String method,
    String path, {
    String? secret,
    String body = '',
  }) async {
    final query = PusherSignature.signRequest(
      key: app.key,
      secret: secret ?? app.secret,
      method: method,
      path: path,
      body: body,
    );
    final client = HttpClient();
    addTearDown(client.close);
    final request = await client.openUrl(
      method,
      Uri.http('127.0.0.1:${engine.port}', path, query),
    );
    if (body.isNotEmpty) {
      request.headers.contentType = ContentType.json;
      request.write(body);
    }
    return request.close();
  }

  Future<void> publish(BroadcastApp target, String channel, Object data) async {
    final body = jsonEncode({
      'name': 'news',
      'channel': channel,
      'data': jsonEncode(data),
    });
    final response = await api(
      target,
      'POST',
      '/apps/${target.id}/events',
      body: body,
    );
    expect(response.statusCode, 200);
    await response.drain<void>();
  }

  test('an unknown key is refused with 4001', () async {
    final client = await _Client.open(url('nope'));
    final first = await client.next();
    expect(_data(first)['code'], 4001);
  });

  test('the same channel name in two applications is two channels', () async {
    final a = await _Client.connect(url(appA.key));
    final b = await _Client.connect(url(appB.key));
    await a.subscribe('news');
    await b.subscribe('news');
    await publish(appB, 'news', {'to': 'b'});
    final frame = await b.next();
    expect(frame['channel'], 'news', reason: 'clients see the plain name');
    expect(jsonDecode(frame['data']! as String), {'to': 'b'});
    await publish(appA, 'news', {'to': 'a'});
    expect(jsonDecode((await a.next())['data']! as String), {'to': 'a'});
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(a.pending, isEmpty, reason: 'b\'s message never reached a');
    expect(b.pending, isEmpty, reason: 'a\'s message never reached b');
    await a.close();
    await b.close();
  });

  test(
    'a private channel needs the authorization of its own application',
    () async {
      final b = await _Client.connect(url(appB.key));
      final socket = _data(b.established)['socket_id']! as String;
      String auth(String secret) => PusherSignature.authorizeChannel(
        key: appB.key,
        secret: secret,
        socketId: socket,
        channel: 'private-room',
      )['auth']!;
      b.send({
        'event': 'pusher:subscribe',
        'data': {'channel': 'private-room', 'auth': auth(appA.secret)},
      });
      expect(_data((await b.next()))['code'], 4009);
      b.send({
        'event': 'pusher:subscribe',
        'data': {'channel': 'private-room', 'auth': auth(appB.secret)},
      });
      expect(
        (await b.next())['event'],
        'pusher_internal:subscription_succeeded',
      );
      await b.close();
    },
  );

  test('each application has its own connection quota', () async {
    final first = await _Client.connect(url(appB.key));
    final refused = await _Client.open(url(appB.key));
    expect(_data((await refused.next()))['code'], 4004);
    final a1 = await _Client.connect(url(appA.key));
    final a2 = await _Client.connect(url(appA.key));
    expect(a2.established['event'], 'pusher:connection_established');
    for (final client in [first, a1, a2]) {
      await client.close();
    }
  });

  test('the HTTP API answers with the application\'s own channels, signed '
      'with its own secret', () async {
    final a = await _Client.connect(url(appA.key));
    final b = await _Client.connect(url(appB.key));
    await a.subscribe('only-a');
    await b.subscribe('only-b');
    Future<Map<String, Object?>> channels(BroadcastApp target) async {
      final response = await api(target, 'GET', '/apps/${target.id}/channels');
      return jsonDecode(await utf8.decodeStream(response))
          as Map<String, Object?>;
    }

    expect((await channels(appA))['channels'], {'only-a': <String, Object?>{}});
    expect((await channels(appB))['channels'], {'only-b': <String, Object?>{}});
    final forged = await api(
      appB,
      'GET',
      '/apps/${appB.id}/channels',
      secret: appA.secret,
    );
    expect(forged.statusCode, 401);
    await forged.drain<void>();
    await a.close();
    await b.close();
  });

  test(
    'a channel name with ":" (another application\'s topic) is refused',
    () async {
      final a = await _Client.connect(url(appA.key));
      a.send({
        'event': 'pusher:subscribe',
        'data': {'channel': '${appB.id}:news'},
      });
      expect(_data((await a.next()))['code'], 4300);
      final response = await api(
        appA,
        'POST',
        '/apps/${appA.id}/events',
        body: jsonEncode({'name': 'x', 'channel': '7:news', 'data': '{}'}),
      );
      expect(response.statusCode, 422);
      await response.drain<void>();
      await a.close();
    },
  );
}

final class _Client {
  _Client(this.socket) {
    socket.listen((message) {
      final frame = jsonDecode(message as String) as Map<String, Object?>;
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(frame);
      } else {
        pending.add(frame);
      }
    }, onDone: () {});
  }

  static Future<_Client> open(String url) async =>
      _Client(await WebSocket.connect(url));

  static Future<_Client> connect(String url) async {
    final client = await open(url);
    client.established = await client.next();
    return client;
  }

  final WebSocket socket;
  final List<Map<String, Object?>> pending = [];
  final List<Completer<Map<String, Object?>>> _waiting = [];
  late final Map<String, Object?> established;

  Future<Map<String, Object?>> next() {
    if (pending.isNotEmpty) {
      return Future.value(pending.removeAt(0));
    }
    final waiting = Completer<Map<String, Object?>>();
    _waiting.add(waiting);
    return waiting.future.timeout(const Duration(seconds: 5));
  }

  void send(Map<String, Object?> frame) => socket.add(jsonEncode(frame));

  Future<void> subscribe(String channel) async {
    send({
      'event': 'pusher:subscribe',
      'data': {'channel': channel},
    });
    expect((await next())['event'], 'pusher_internal:subscription_succeeded');
  }

  Future<void> close() async {
    await socket.close();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// The decoded `data` of a Pusher [frame].
Map<String, Object?> _data(Map<String, Object?> frame) =>
    jsonDecode(frame['data']! as String) as Map<String, Object?>;
