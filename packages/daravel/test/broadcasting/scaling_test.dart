import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

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
/// ([configure] registers its driver), and through Redis by
/// daravel_redis/test/scaling_test.dart ([env] picks the driver).
void scalingTests({
  String? databaseUrl,
  ApplicationBuilder Function(ApplicationBuilder builder)? configure,
  Map<String, String> env = const {},
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
          ...env,
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

  test('the relay started by the first connection keeps relaying after that '
      'connection (its request) has ended', () async {
    // Starts server a's relay, in the zone of this connection's request.
    final first = await connect(0);
    await first.close();
    // The request is over; the relay must still read the other servers.
    await Future<void>.delayed(const Duration(seconds: 2));
    final later = await connect(0);
    await later.subscribe('news');
    final (status, body) = await api(1, 'POST', '/apps/$appId/events', {
      'name': 'published',
      'data': '{"title":"late"}',
      'channels': ['news'],
    });
    expect(status, 200, reason: body);
    final received = await later.next().timeout(const Duration(seconds: 5));
    expect(received['event'], 'published');
    await later.close();
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

  final redis = env['REVERB_SCALING_DRIVER'] == 'redis';

  Future<T> onServer<T>(int index, Future<T> Function(DatabaseManager db) fn) =>
      servers[index].$1.run(() => fn(App.make<DatabaseManager>()));

  test('the group runs on the database it names', () async {
    final config = servers[0].$1.config.section<DatabaseConfig>();
    final driver = config.connections[config.defaultConnection]!.driver;
    final runtime = await onServer(
      0,
      (db) async => (await db.connection()).runtimeType.toString(),
    );
    if (databaseUrl == null) {
      expect((driver, runtime), ('sqlite', 'SqliteDriver'));
    } else {
      // DB_URL gives the default connection (named sqlite) its driver.
      expect(driver, isNot('sqlite'));
      expect(runtime, isNot('SqliteDriver'));
      expect(databaseUrl, startsWith(driver == 'pgsql' ? 'postgres' : driver));
    }
  });

  test('the relay a connection starts reads with no request scope after '
      'that connection ended (Review #149)', () async {
    final scopes = <Scope?>[];
    final stop = await onServer(
      0,
      (db) async => db.listen((event) {
        if (event.sql.contains('broadcast_messages')) {
          scopes.add(Container.currentOrNull?.currentScope);
        }
      }),
    );
    addTearDown(stop);
    final first = await connect(0); // starts server a's relay
    await first.close();
    scopes.clear();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (scopes.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(scopes, isNotEmpty, reason: 'the relay reads');
    expect(scopes, everyElement(isNull), reason: 'not the request\'s scope');
  }, skip: redis ? 'database relay' : false);

  Future<int> memberRows() => onServer(
    0,
    (db) async => (await db.table('broadcast_members').get()).length,
  );

  Future<void> eventually(Future<bool> Function() condition) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (!await condition() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(await condition(), isTrue);
  }

  test('subscribing twice to a channel leaves one member row, and none '
      'after close (#153)', () async {
    final client = await connect(0);
    final first = await joinPresence(client, 'presence-dup', 1, 'Teo');
    final again = await joinPresence(client, 'presence-dup', 1, 'Teo');
    expect(_presence(first)['count'], 1);
    expect(_presence(again)['count'], 1);
    expect(await memberRows(), 1);
    await client.close();
    await eventually(() async => await memberRows() == 0);
    final (_, body) = await api(
      1,
      'GET',
      '/apps/$appId/channels/presence-dup',
      null,
      {'info': 'user_count'},
    );
    expect(jsonDecode(body), {'occupied': false, 'user_count': 0});
  }, skip: redis ? 'database rows' : false);

  test('a worker forgets the members its previous life left (#153)', () async {
    // What a crashed worker of the same name left: its rows count while
    // the process beats, so the respawned worker deletes them.
    final worker = Isolate.current.debugName;
    final instance = worker == null ? 'a' : 'a/$worker';
    await onServer(0, (db) async {
      await db.table('broadcast_members').insert(<String, Object?>{
        'server': instance,
        'socket': '9.9',
        'channel': 'presence-ghost',
        'user_id': '9',
        'user_info': null,
        'created_at': 0,
      });
      await db
          .table('broadcast_servers')
          .upsert(
            <String, Object?>{
              'server': instance,
              'seen_at': DateTime.now().millisecondsSinceEpoch ~/ 1000,
            },
            const ['server'],
          );
    });
    expect(await memberRows(), 1);
    // The first client starts the relay, whose first beat forgets them.
    final client = await connect(0);
    expect(await memberRows(), 0);
    final (_, body) = await api(
      1,
      'GET',
      '/apps/$appId/channels/presence-ghost',
      null,
      {'info': 'user_count'},
    );
    expect(jsonDecode(body), {'occupied': false, 'user_count': 0});
    await client.close();
  }, skip: redis ? 'database rows' : false);

  test('an idle relay reads less and less often, and close() waits for '
      'its loop (#153)', () async {
    final client = await connect(0); // starts server a's relay
    var reads = 0;
    await onServer(0, (db) async {
      db.listen((event) {
        if (event.sql.contains('broadcast_messages')) {
          reads++;
        }
      });
    });
    // At REVERB_SCALING_POLL=20ms an idle relay read about 75 times in
    // 1.5 s; backing off to one read a second it reads a handful.
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(reads, lessThan(15));
    await client.close();
    final relay = servers[0].$1.container
        .make<BroadcastManager>()
        .server!
        .relay!;
    await relay.close();
    final after = reads;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(reads, after, reason: 'nothing reads after close()');
  }, skip: redis ? 'database relay' : false);
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
