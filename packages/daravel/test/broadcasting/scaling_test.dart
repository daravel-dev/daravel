import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import '../database/support/test_databases.dart';

const appId = 'app1';
const appKey = 'key1';
const appSecret = 'secret1';

/// Two servers (`REVERB_SCALING_ENABLED`): two applications with their own
/// coordinators, as two machines have, sharing only a database. A client
/// on one sees what happens on the other. On SQLite (one file) the servers
/// poll; on PostgreSQL (`DARAVEL_TEST_PG`) `NOTIFY` wakes them.
void main() {
  group('sqlite file', scalingTests);
  final url = Platform.environment['DARAVEL_TEST_PG'];
  if (url != null && url.isNotEmpty) {
    group('pgsql', () => scalingTests(databaseUrl: url), tags: 'integration');
  }
}

/// Also run on MySQL and MariaDB by daravel_mysql/test/orm_matrix_test.dart
/// ([configure] registers its driver).
void scalingTests({
  String? databaseUrl,
  ApplicationBuilder Function(ApplicationBuilder builder)? configure,
}) {
  late Directory dir;
  final servers = <(Application, ServerEngine)>[];

  Future<ServerEngine> server(String id) async {
    final builder = Application.configure(basePath: dir.path);
    final app = (configure?.call(builder) ?? builder)
        .withEnv({
          'APP_ENV': 'testing',
          if (databaseUrl == null)
            'DB_DATABASE': '${dir.path}/shared.sqlite'
          else
            'DB_URL': databaseUrl,
          'REVERB_APP_ID': appId,
          'REVERB_APP_KEY': appKey,
          'REVERB_APP_SECRET': appSecret,
          'REVERB_SCALING_ENABLED': 'true',
          'REVERB_SCALING_POLL': '20ms',
          'REVERB_SERVER_ID': id,
        })
        .withBroadcasting()
        .create();
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
    servers.add((app, engine));
    return engine;
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('daravel_scaling_');
    final first = await server('a');
    // Only these tables: other suites share the test database.
    await servers.first.$1.run(() async {
      final schema = await freshSchema(App.make<DatabaseManager>(), const [
        'broadcast_messages',
        'broadcast_members',
        'broadcast_servers',
        'broadcast_cache',
      ]);
      await const CreateBroadcastingTables().up(schema);
    });
    expect(first.port, isPositive);
    await server('b');
  });

  tearDown(() async {
    for (final (app, engine) in servers.reversed) {
      await engine.stop();
      await app.shutdown();
    }
    servers.clear();
    dir.deleteSync(recursive: true);
  });

  Future<_Client> connect(int index) => _Client.connect(
    'ws://127.0.0.1:${servers[index].$2.port}/app/$appKey?protocol=7',
  );

  Future<(int, String)> api(
    int index,
    String method,
    String path, [
    Object? body,
    Map<String, String> query = const {},
  ]) async {
    final text = body == null ? '' : jsonEncode(body);
    final signed = PusherSignature.signRequest(
      key: appKey,
      secret: appSecret,
      method: method,
      path: path,
      body: text,
      query: query,
    );
    final client = HttpClient();
    final request = await client.openUrl(
      method,
      Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: servers[index].$2.port,
        path: path,
        queryParameters: signed,
      ),
    );
    if (text.isNotEmpty) {
      request.headers.contentType = ContentType.json;
      request.write(text);
    }
    final response = await request.close();
    final result = await response.transform(utf8.decoder).join();
    client.close();
    return (response.statusCode, result);
  }

  Future<Map<String, Object?>> joinPresence(
    _Client client,
    String channel,
    int userId,
    String name,
  ) {
    final data = jsonEncode({
      'user_id': userId,
      'user_info': {'name': name},
    });
    return client.subscribe(
      channel,
      auth: PusherSignature.authorizeChannel(
        key: appKey,
        secret: appSecret,
        socketId: client.socketId,
        channel: channel,
        channelData: data,
      )['auth'],
      channelData: data,
    );
  }

  test('an event published on one server reaches clients of the other, '
      'once, and not the sender\'s socket', () async {
    final onA = await connect(0);
    final onB = await connect(1);
    await onA.subscribe('news');
    await onB.subscribe('news');

    final (status, body) = await api(0, 'POST', '/apps/$appId/events', {
      'name': 'published',
      'data': '{"title":"hi"}',
      'channels': ['news'],
      'socket_id': onA.socketId,
    });
    expect(status, 200, reason: body);
    final received = await onB.next();
    expect(received['event'], 'published');
    expect(received['channel'], 'news');
    // toOthers: the sender's socket on server A gets nothing, and B no copy.
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(onA.pending, isEmpty);
    expect(onB.pending, isEmpty);
    await onA.close();
    await onB.close();
  });

  test('presence members, member_added and member_removed across servers, '
      'and the channels API of either server', () async {
    final teo = await connect(0);
    final ana = await connect(1);

    final first = await joinPresence(teo, 'presence-room', 1, 'Teo');
    expect(_presence(first)['count'], 1);

    final second = await joinPresence(ana, 'presence-room', 2, 'Ana');
    expect(_presence(second)['count'], 2);
    expect(_presence(second)['hash'], {
      '1': {'name': 'Teo'},
      '2': {'name': 'Ana'},
    });

    final added = await teo.next();
    expect(added['event'], 'pusher_internal:member_added');
    expect(jsonDecode(added['data']! as String), {
      'user_id': '2',
      'user_info': {'name': 'Ana'},
    });

    final (status, body) = await api(
      0,
      'GET',
      '/apps/$appId/channels/presence-room',
      null,
      {'info': 'user_count,subscription_count'},
    );
    expect(status, 200);
    expect(jsonDecode(body), {
      'occupied': true,
      'subscription_count': 2,
      'user_count': 2,
    });

    await ana.close();
    final removed = await teo.next();
    expect(removed['event'], 'pusher_internal:member_removed');
    expect(jsonDecode(removed['data']! as String), {'user_id': '2'});
    await teo.close();
  });

  test('a cache channel\'s last event reaches a late subscriber of the '
      'other server', () async {
    final (status, _) = await api(0, 'POST', '/apps/$appId/events', {
      'name': 'price',
      'data': '{"price":13}',
      'channel': 'cache-prices',
    });
    expect(status, 200);
    final late = await connect(1);
    await late.subscribe('cache-prices');
    final cached = await late.next();
    expect(cached['event'], 'price');
    await late.close();
  });
}

Map<String, Object?> _presence(Map<String, Object?> succeeded) =>
    (jsonDecode(succeeded['data']! as String)
            as Map<String, Object?>)['presence']!
        as Map<String, Object?>;

final class _Client {
  _Client(this.socket) {
    socket.listen((message) {
      final frame = jsonDecode(message as String) as Map<String, Object?>;
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(frame);
      } else {
        pending.add(frame);
      }
    });
  }

  static Future<_Client> connect(String url) async {
    final client = _Client(await WebSocket.connect(url));
    client.established = await client.next();
    return client;
  }

  final WebSocket socket;
  final List<Map<String, Object?>> pending = [];
  final List<Completer<Map<String, Object?>>> _waiting = [];
  late final Map<String, Object?> established;

  String get socketId =>
      (jsonDecode(established['data']! as String)
              as Map<String, Object?>)['socket_id']!
          as String;

  Future<Map<String, Object?>> next() {
    if (pending.isNotEmpty) {
      return Future.value(pending.removeAt(0));
    }
    final waiting = Completer<Map<String, Object?>>();
    _waiting.add(waiting);
    return waiting.future.timeout(const Duration(seconds: 5));
  }

  void send(Map<String, Object?> frame) => socket.add(jsonEncode(frame));

  Future<Map<String, Object?>> subscribe(
    String channel, {
    String? auth,
    String? channelData,
  }) async {
    send({
      'event': 'pusher:subscribe',
      'data': {'channel': channel, 'auth': ?auth, 'channel_data': ?channelData},
    });
    final frame = await next();
    expect(frame['event'], 'pusher_internal:subscription_succeeded');
    return frame;
  }

  Future<void> close() async {
    await socket.close();
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
