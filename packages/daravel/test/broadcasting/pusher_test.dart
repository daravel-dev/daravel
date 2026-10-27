import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/broadcasting/secretbox.dart';
import 'package:test/test.dart';

final class Member implements Authenticatable {
  const Member(this.id, this.name);
  final int id;
  final String name;
  @override
  Object get authIdentifier => id;
  @override
  String get authIdentifierName => 'id';
  @override
  String? get authPassword => null;
  @override
  String get authPasswordName => 'password';
  @override
  String? get rememberToken => null;
}

final class OrderShipped with ShouldBroadcast {
  OrderShipped(this.id);
  final int id;
  @override
  List<String> broadcastOn() => ['private-orders.$id'];
  @override
  Map<String, Object?> broadcastWith() => {'id': id, 'status': 'shipped'};
}

const String appId = '42';
const String appKey = 'daravel-key';
const String appSecret = 'daravel-secret';
final List<int> masterKey = List.filled(32, 0x2a);

/// base64 of 32 0x2a bytes ([masterKey]).
const String masterKeyBase64 = 'KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKio=';

void main() {
  late Application app;
  late ServerEngine engine;

  setUp(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'REVERB_APP_ID': appId,
          'REVERB_APP_KEY': appKey,
          'REVERB_APP_SECRET': appSecret,
          'REVERB_ENCRYPTION_MASTER_KEY_BASE64': masterKeyBase64,
        })
        .withAuth((auth) {
          auth.register(
            'token',
            ClosureGuard<Member>(
              name: 'token',
              resolver: (request) => switch (request.bearerToken()) {
                'user-1' => const Member(1, 'Teo'),
                'user-2' => const Member(2, 'Ana'),
                _ => null,
              },
            ),
          );
        })
        .withBroadcasting(
          channels: (channels) {
            channels
              ..channel('orders.{id}', (user, p) => p['id'] == '7')
              ..channel(
                'cache-chat.{room}',
                (user, p) => {'name': (user as Member).name},
              )
              ..channel(
                'chat.{room}',
                (user, p) => {'name': (user as Member).name},
              );
          },
        )
        .withRouting(
          api: (r) {
            r.post('/ship/{id}', (request) async {
              await Event.dispatch(OrderShipped(request.param<int>('id')));
              return Response.noContent();
            });
          },
        )
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

  Future<_Client> connect([String key = appKey]) =>
      _Client.connect('ws://127.0.0.1:${engine.port}/app/$key?protocol=7');

  /// Laravel's `/broadcasting/auth`, as Echo calls it.
  Future<(int, Map<String, Object?>)> authorize(
    String socketId,
    String channel, {
    String? token,
  }) async {
    final client = HttpClient();
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:${engine.port}/broadcasting/auth'),
    );
    request.headers
      ..contentType = ContentType('application', 'x-www-form-urlencoded')
      ..set('accept', 'application/json');
    if (token != null) {
      request.headers.set('authorization', 'Bearer $token');
    }
    request.write('socket_id=$socketId&channel_name=$channel');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    client.close();
    return (response.statusCode, jsonDecode(body) as Map<String, Object?>);
  }

  /// A signed API call, as pusher-php-server makes it.
  Future<(int, String)> api(
    String method,
    String path,
    Object? body, {
    String secret = appSecret,
    Map<String, String> query = const {},
  }) async {
    final text = body == null ? '' : jsonEncode(body);
    final signed = PusherSignature.signRequest(
      key: appKey,
      secret: secret,
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
        port: engine.port,
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

  Future<void> trigger(
    String name,
    List<String> channels,
    Object data, {
    String? socketId,
  }) async {
    final (status, body) = await api('POST', '/apps/$appId/events', {
      'name': name,
      'data': jsonEncode(data),
      'channels': channels,
      'socket_id': ?socketId,
    });
    expect(status, 200, reason: body);
  }

  test(
    'connection_established, ping and errors as Reverb sends them',
    () async {
      final client = await connect();
      expect(client.socketId, matches(RegExp(r'^\d+\.\d+$')));
      expect(client.activityTimeout, 30);

      client.send({'event': 'pusher:ping', 'data': <String, Object?>{}});
      expect(await client.next(), {'event': 'pusher:pong'});

      client.socket.add('not json');
      expect(await client.next(), {
        'event': 'pusher:error',
        'data': jsonEncode({'code': 4200, 'message': 'Invalid message format'}),
      });
      await client.close();

      final wrong = await connect('nope');
      expect(wrong.established['event'], 'pusher:error');
      expect(jsonDecode(wrong.established['data']! as String), {
        'code': 4001,
        'message': 'Application does not exist',
      });
      await wrong.close();
    },
  );

  test('a public channel receives events from the HTTP API', () async {
    final client = await connect();
    await client.subscribe('news');
    await trigger('App\\Events\\Published', ['news'], {'title': 'Hello'});
    final frame = await client.next();
    expect(frame['event'], r'App\Events\Published');
    expect(frame['channel'], 'news');
    expect(jsonDecode(frame['data']! as String), {'title': 'Hello'});
    await client.close();
  });

  test('the HTTP API refuses bad signatures, unknown apps and old requests', () async {
    final event = {
      'name': 'x',
      'data': '{}',
      'channels': ['news'],
    };
    expect(
      (await api('POST', '/apps/$appId/events', event, secret: 'wrong')).$1,
      401,
    );
    expect((await api('POST', '/apps/7/events', event)).$1, 404);
    final old = {
      'auth_timestamp':
          '${DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000}',
    };
    // The signature covers the old timestamp, so only the age refuses it.
    final (status, _) = await api(
      'POST',
      '/apps/$appId/events',
      event,
      query: old,
    );
    expect(status, 200, reason: 'signRequest sets a fresh timestamp');
    expect(
      PusherSignature.verifyRequest(
        secret: appSecret,
        method: 'POST',
        path: '/apps/$appId/events',
        query: {
          ...PusherSignature.signRequest(
            key: appKey,
            secret: appSecret,
            method: 'POST',
            path: '/apps/$appId/events',
          ),
          ...old,
        },
        body: '',
      ),
      isFalse,
    );
    expect((await api('POST', '/apps/$appId/events', {'name': 'x'})).$1, 422);
  });

  test(
    '/broadcasting/auth signs private channels the callback allows',
    () async {
      final client = await connect();
      final (status, body) = await authorize(
        client.socketId,
        'private-orders.7',
        token: 'user-1',
      );
      expect(status, 200);
      expect(body['auth'], startsWith('$appKey:'));
      expect(
        PusherSignature.verifyChannel(
          secret: appSecret,
          socketId: client.socketId,
          channel: 'private-orders.7',
          auth: body['auth'] as String?,
        ),
        isTrue,
      );
      expect(
        (await authorize(
          client.socketId,
          'private-orders.8',
          token: 'user-1',
        )).$1,
        403,
      );
      expect((await authorize(client.socketId, 'private-orders.7')).$1, 401);
      expect(
        (await authorize(
          client.socketId,
          'private-unknown',
          token: 'user-1',
        )).$1,
        403,
      );

      await client.subscribe('private-orders.7', auth: body['auth']! as String);
      await client.close();
    },
  );

  test('a private channel needs a valid signature', () async {
    final client = await connect();
    client.send({
      'event': 'pusher:subscribe',
      'data': {'channel': 'private-orders.7', 'auth': '$appKey:forged'},
    });
    final frame = await client.next();
    expect(frame['event'], 'pusher:error');
    expect(jsonDecode(frame['data']! as String), {
      'code': 4009,
      'message': 'Connection is unauthorized',
    });
    await client.close();
  });

  test('presence channels: members, member_added and member_removed', () async {
    final teo = await connect();
    final (_, teoAuth) = await authorize(
      teo.socketId,
      'presence-chat.1',
      token: 'user-1',
    );
    final joined = await teo.subscribe(
      'presence-chat.1',
      auth: teoAuth['auth']! as String,
      channelData: teoAuth['channel_data']! as String,
    );
    expect(jsonDecode(teoAuth['channel_data']! as String), {
      'user_id': '1',
      'user_info': {'name': 'Teo'},
    });
    expect(jsonDecode(joined['data']! as String), {
      'presence': {
        'count': 1,
        'ids': ['1'],
        'hash': {
          '1': {'name': 'Teo'},
        },
      },
    });

    final ana = await connect();
    final (_, anaAuth) = await authorize(
      ana.socketId,
      'presence-chat.1',
      token: 'user-2',
    );
    final anaJoined = await ana.subscribe(
      'presence-chat.1',
      auth: anaAuth['auth']! as String,
      channelData: anaAuth['channel_data']! as String,
    );
    expect(
      (jsonDecode(anaJoined['data']! as String) as Map)['presence'],
      containsPair('ids', ['1', '2']),
    );
    final added = await teo.next();
    expect(added['event'], 'pusher_internal:member_added');
    expect(jsonDecode(added['data']! as String), {
      'user_id': '2',
      'user_info': {'name': 'Ana'},
    });

    // Teo in a second tab: one member, so nobody hears member_added.
    final teo2 = await connect();
    final (_, teo2Auth) = await authorize(
      teo2.socketId,
      'presence-chat.1',
      token: 'user-1',
    );
    await teo2.subscribe(
      'presence-chat.1',
      auth: teo2Auth['auth']! as String,
      channelData: teo2Auth['channel_data']! as String,
    );
    await teo2.close();

    await ana.close();
    final removed = await teo.next();
    expect(removed['event'], 'pusher_internal:member_removed');
    expect(jsonDecode(removed['data']! as String), {'user_id': '2'});
    await teo.close();
  });

  test('client events reach the others on private channels only', () async {
    Future<_Client> join() async {
      final client = await connect();
      final (_, body) = await authorize(
        client.socketId,
        'private-orders.7',
        token: 'user-1',
      );
      await client.subscribe('private-orders.7', auth: body['auth']! as String);
      await client.subscribe('news');
      return client;
    }

    final a = await join();
    final b = await join();
    a
      ..send({
        'event': 'client-typing',
        'channel': 'news',
        'data': {'who': 'a'},
      })
      ..send({
        'event': 'client-typing',
        'channel': 'private-orders.7',
        'data': {'who': 'a'},
      });
    final whisper = await b.next();
    expect(whisper, {
      'event': 'client-typing',
      'channel': 'private-orders.7',
      'data': {'who': 'a'},
    });
    // Not back to the sender, and nothing on the public channel.
    a.send({'event': 'pusher:ping', 'data': <String, Object?>{}});
    expect(await a.next(), {'event': 'pusher:pong'});
    await a.close();
    await b.close();
  });

  test('socket_id leaves the sender out (toOthers)', () async {
    final a = await connect();
    final b = await connect();
    await a.subscribe('news');
    await b.subscribe('news');
    await trigger('x', ['news'], {'n': 1}, socketId: a.socketId);
    expect((await b.next())['event'], 'x');
    a.send({'event': 'pusher:ping', 'data': <String, Object?>{}});
    expect(await a.next(), {'event': 'pusher:pong'});
    await a.close();
    await b.close();
  });

  test('ShouldBroadcast events are broadcast when dispatched', () async {
    final client = await connect();
    final (_, body) = await authorize(
      client.socketId,
      'private-orders.7',
      token: 'user-1',
    );
    await client.subscribe('private-orders.7', auth: body['auth']! as String);
    final http = HttpClient();
    final response = await (await http.postUrl(
      Uri.parse('http://127.0.0.1:${engine.port}/api/ship/7'),
    )).close();
    await response.drain<void>();
    http.close();
    final frame = await client.next();
    expect(frame['event'], r'App\Events\OrderShipped');
    expect(jsonDecode(frame['data']! as String), {
      'id': 7,
      'status': 'shipped',
    });
    await client.close();
  });

  test(
    'cache channels: cache_miss, then the last event for new subscribers',
    () async {
      final first = await connect();
      await first.subscribe('cache-prices');
      expect(await first.next(), {
        'event': 'pusher:cache_miss',
        'channel': 'cache-prices',
      });
      await trigger(
        'price.updated',
        ['cache-prices'],
        {'sku': 'A1', 'price': 12},
      );
      await trigger(
        'price.updated',
        ['cache-prices'],
        {'sku': 'A1', 'price': 13},
      );
      expect((await first.next())['event'], 'price.updated');
      expect((await first.next())['event'], 'price.updated');

      // A later subscriber gets the last event right after subscribing, even
      // when nobody else is listening any more (as Pusher, not Reverb).
      await first.close();
      final later = await connect();
      await later.subscribe('cache-prices');
      final cached = await later.next();
      expect(cached['event'], 'price.updated');
      expect(cached['channel'], 'cache-prices');
      expect(jsonDecode(cached['data']! as String), {'sku': 'A1', 'price': 13});
      await later.close();

      // Kept for 30 minutes.
      Clock.freeze();
      addTearDown(Clock.restore);
      Clock.travel(const Duration(minutes: 31));
      final expired = await connect();
      await expired.subscribe('cache-prices');
      expect((await expired.next())['event'], 'pusher:cache_miss');
      await expired.close();
    },
  );

  test('presence cache channels keep events, not member changes', () async {
    final teo = await connect();
    final (_, auth) = await authorize(
      teo.socketId,
      'presence-cache-chat.1',
      token: 'user-1',
    );
    await teo.subscribe(
      'presence-cache-chat.1',
      auth: auth['auth']! as String,
      channelData: auth['channel_data']! as String,
    );
    expect((await teo.next())['event'], 'pusher:cache_miss');
    final ana = await connect();
    final (_, anaAuth) = await authorize(
      ana.socketId,
      'presence-cache-chat.1',
      token: 'user-2',
    );
    await ana.subscribe(
      'presence-cache-chat.1',
      auth: anaAuth['auth']! as String,
      channelData: anaAuth['channel_data']! as String,
    );
    // member_added is not cached, so Ana still gets cache_miss.
    expect((await ana.next())['event'], 'pusher:cache_miss');
    expect((await teo.next())['event'], 'pusher_internal:member_added');
    await teo.close();
    await ana.close();
  });

  test(
    'end-to-end encrypted channels: shared_secret, ciphertext, no whispers',
    () async {
      final client = await connect();
      final (status, body) = await authorize(
        client.socketId,
        'private-encrypted-orders.7',
        token: 'user-1',
      );
      expect(status, 200);
      final secret = base64.decode(body['shared_secret']! as String);
      expect(
        secret,
        PusherEncryption.sharedSecret('private-encrypted-orders.7', masterKey),
      );
      await client.subscribe(
        'private-encrypted-orders.7',
        auth: body['auth']! as String,
      );
      await client.subscribe('news');

      await app.container.make<BroadcastManager>().send(
        r'App\Events\Shipped',
        ['private-encrypted-orders.7', 'news'],
        {'id': 7},
      );
      final frames = [await client.next(), await client.next()];
      final encrypted = frames.firstWhere(
        (f) => f['channel'] == 'private-encrypted-orders.7',
      );
      final plain = frames.firstWhere((f) => f['channel'] == 'news');
      expect(jsonDecode(plain['data']! as String), {'id': 7});
      final box =
          jsonDecode(encrypted['data']! as String) as Map<String, Object?>;
      expect(box.keys, unorderedEquals(['nonce', 'ciphertext']));
      expect(
        utf8.decode(
          Secretbox.open(
            base64.decode(box['ciphertext']! as String),
            base64.decode(box['nonce']! as String),
            secret,
          )!,
        ),
        '{"id":7}',
      );

      // Client events are not relayed on encrypted channels.
      final other = await connect();
      final (_, otherAuth) = await authorize(
        other.socketId,
        'private-encrypted-orders.7',
        token: 'user-2',
      );
      await other.subscribe(
        'private-encrypted-orders.7',
        auth: otherAuth['auth']! as String,
      );
      client.send({
        'event': 'client-typing',
        'channel': 'private-encrypted-orders.7',
        'data': <String, Object?>{},
      });
      other.send({'event': 'pusher:ping', 'data': <String, Object?>{}});
      expect(await other.next(), {'event': 'pusher:pong'});
      await client.close();
      await other.close();
    },
  );

  test('the encryption master key must be 32 bytes of base64', () {
    expect(
      () => BroadcastConfig.fromEnv(
        Env.fromMap({
          'REVERB_ENCRYPTION_MASTER_KEY_BASE64': base64.encode([1, 2]),
        }),
      ),
      throwsA(isA<ConfigException>()),
    );
    expect(
      () => BroadcastConfig.fromEnv(
        Env.fromMap(const {'REVERB_ENCRYPTION_MASTER_KEY_BASE64': '***'}),
      ),
      throwsA(isA<ConfigException>()),
    );
  });

  test('the HTTP API reports channels and presence users', () async {
    final client = await connect();
    await client.subscribe('news');
    final (_, auth) = await authorize(
      client.socketId,
      'presence-chat.1',
      token: 'user-2',
    );
    await client.subscribe(
      'presence-chat.1',
      auth: auth['auth']! as String,
      channelData: auth['channel_data']! as String,
    );
    final (_, channels) = await api(
      'GET',
      '/apps/$appId/channels',
      null,
      query: const {'info': 'user_count'},
    );
    expect(jsonDecode(channels), {
      'channels': {
        'news': <String, Object?>{},
        'presence-chat.1': {'user_count': 1},
      },
    });
    final (_, channel) = await api(
      'GET',
      '/apps/$appId/channels/news',
      null,
      query: const {'info': 'subscription_count'},
    );
    expect(jsonDecode(channel), {'occupied': true, 'subscription_count': 1});
    final (_, users) = await api(
      'GET',
      '/apps/$appId/channels/presence-chat.1/users',
      null,
    );
    expect(jsonDecode(users), {
      'users': [
        {'id': '2'},
      ],
    });
    await client.close();
  });
}

/// A Pusher client speaking protocol 7, as pusher-js does.
final class _Client {
  _Client(this.socket) {
    socket.listen((message) {
      final frame = jsonDecode(message as String) as Map<String, Object?>;
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(frame);
      } else {
        _frames.add(frame);
      }
    });
  }

  static Future<_Client> connect(String url) async {
    final client = _Client(await WebSocket.connect(url));
    client.established = await client.next();
    return client;
  }

  final WebSocket socket;
  final List<Map<String, Object?>> _frames = [];
  final List<Completer<Map<String, Object?>>> _waiting = [];
  late final Map<String, Object?> established;

  Map<String, Object?> get _connection =>
      jsonDecode(established['data']! as String) as Map<String, Object?>;
  String get socketId => _connection['socket_id']! as String;
  int get activityTimeout => _connection['activity_timeout']! as int;

  Future<Map<String, Object?>> next() {
    if (_frames.isNotEmpty) {
      return Future.value(_frames.removeAt(0));
    }
    final waiting = Completer<Map<String, Object?>>();
    _waiting.add(waiting);
    return waiting.future.timeout(const Duration(seconds: 5));
  }

  void send(Map<String, Object?> frame) => socket.add(jsonEncode(frame));

  /// Subscribes and returns `pusher_internal:subscription_succeeded`.
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
    expect(frame['channel'], channel);
    return frame;
  }

  Future<void> close() async {
    await socket.close();
    // Let the server see the close (member_removed, unsubscribes).
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}
