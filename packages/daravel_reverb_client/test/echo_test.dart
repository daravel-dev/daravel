import 'dart:async';
import 'dart:convert';

import 'package:daravel_reverb_client/daravel_reverb_client.dart';
import 'package:daravel_reverb_client/src/secretbox.dart';
import 'package:test/test.dart';

import 'fake_pusher.dart';

void main() {
  late FakePusher server;
  final clients = <Echo>[];

  setUp(() async => server = await FakePusher.start());

  tearDown(() async {
    for (final echo in clients) {
      await echo.disconnect();
    }
    clients.clear();
    await server.close();
  });

  Echo echo({
    EchoAuth? auth,
    Duration base = const Duration(milliseconds: 20),
  }) {
    final client = Echo.reverb(
      key: 'app-key',
      host: server.host,
      auth: auth,
      reconnectBase: base,
      reconnectMax: const Duration(milliseconds: 200),
    );
    clients.add(client);
    return client;
  }

  Future<void> connected(Echo client) async {
    if (client.connectionState != EchoConnectionState.connected) {
      await client.onConnectionStateChange
          .firstWhere((s) => s == EchoConnectionState.connected)
          .timeout(const Duration(seconds: 5));
    }
  }

  Future<T> eventually<T>(T? Function() value) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final v = value();
      if (v != null) {
        return v;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TimeoutException('never');
  }

  bool subscribeTo(Map<String, Object?> f, String channel) =>
      f['event'] == 'pusher:subscribe' &&
      (f['data']! as Map)['channel'] == channel;

  test('connects with protocol 7 and gets a socket id', () async {
    final client = echo();
    await connected(client);
    expect(client.socketId, '1.1001');
    final uri = server.connections.single;
    expect(uri.path, '/app/app-key');
    expect(uri.queryParameters['protocol'], '7');
    expect(uri.queryParameters['client'], 'daravel_reverb_client');
  });

  test('a path prefix, as REVERB_SERVER_PATH', () async {
    final client = Echo.reverb(
      key: 'k',
      host: server.host,
      path: '/ws/',
      autoConnect: false,
    );
    expect(client.uri.path, '/ws/app/k');
    expect(
      Echo.reverb(key: 'k', host: 'ws.example.com', autoConnect: false).uri,
      Uri.parse(
        'wss://ws.example.com/app/k?protocol=7&client=daravel_reverb_client'
        '&version=$reverbClientVersion&flash=false',
      ),
    );
  });

  test('public channels: event names as Laravel Echo formats them', () async {
    final client = echo();
    final shipped = <Map<String, Object?>>[];
    final raw = <Map<String, Object?>>[];
    final all = <String>[];
    client.channel('orders')
      ..listen('OrderShipped', shipped.add)
      ..listen('.announcement', raw.add)
      ..listenToAll((event, _) => all.add(event));
    await connected(client);
    await server.next((f) => subscribeTo(f, 'orders'));
    await eventually(() => client.channels['orders']!.subscribed ? true : null);
    server
      ..event('orders', r'App\Events\OrderShipped', {'id': 7})
      ..event('orders', 'announcement', 'plain text');
    await eventually(() => raw.isEmpty ? null : true);
    expect(shipped, [
      {'id': 7},
    ]);
    expect(raw, [
      {'data': 'plain text'},
    ]);
    expect(all, [r'App\Events\OrderShipped', 'announcement']);
    expect(client.formatEvent('Orders.Shipped'), r'App\Events\Orders\Shipped');
  });

  test('private channels: the auth endpoint with the bearer token, the '
      'signature in the subscription', () async {
    String? bearer;
    server.authorize = (headers, form) {
      bearer = headers.value('authorization');
      return (200, {'auth': 'app-key:sig-for-${form['channel_name']}'});
    };
    final client = echo(
      auth: EchoAuth.bearer(() => 'token-1', endpoint: server.authEndpoint),
    );
    client.private('orders.7');
    await connected(client);
    final subscribe = await server.next(
      (f) => subscribeTo(f, 'private-orders.7'),
    );
    expect(
      (subscribe['data']! as Map)['auth'],
      'app-key:sig-for-private-orders.7',
    );
    expect(bearer, 'Bearer token-1');
    expect(server.authRequests.single, {
      'socket_id': client.socketId,
      'channel_name': 'private-orders.7',
    });
  });

  test(
    'a refused authorization: no subscription, the error reported',
    () async {
      server.authorize = (_, _) =>
          (403, {'message': 'This action is unauthorized.'});
      final client = echo(auth: EchoAuth.endpoint(server.authEndpoint));
      final errors = <Object>[];
      final reported = <Map<String, Object?>>[];
      client.onError.listen(reported.add);
      client.private('secret').error(errors.add);
      await connected(client);
      await eventually(() => errors.isEmpty ? null : true);
      expect(errors.single, isA<EchoAuthException>());
      expect(reported.single, {'channel': 'private-secret', 'status': 403});
      expect(
        server.received.where((f) => f['event'] == 'pusher:subscribe'),
        isEmpty,
      );
    },
  );

  test('presence: here, joining (once per user), leaving', () async {
    server
      ..presence = {
        '1': {'id': 1, 'name': 'Ana'},
      }
      ..authorize = (_, form) => (
        200,
        {
          'auth': 'app-key:sig',
          'channel_data': jsonEncode({
            'user_id': 2,
            'user_info': {'id': 2, 'name': 'Budi'},
          }),
        },
      );
    final client = echo(auth: EchoAuth.endpoint(server.authEndpoint));
    final here = <List<Map<String, Object?>>>[];
    final joining = <Map<String, Object?>>[];
    final leaving = <Map<String, Object?>>[];
    final room = client.join('chat.lobby')
      ..here(here.add)
      ..joining(joining.add)
      ..leaving(leaving.add);
    await connected(client);
    final subscribe = await server.next(
      (f) => subscribeTo(f, 'presence-chat.lobby'),
    );
    expect((subscribe['data']! as Map)['channel_data'], contains('Budi'));
    await eventually(() => here.isEmpty ? null : true);
    expect(here.single, [
      {'id': 1, 'name': 'Ana'},
    ]);
    final added = {
      'user_id': '3',
      'user_info': {'id': 3, 'name': 'Citra'},
    };
    server
      ..event('presence-chat.lobby', 'pusher_internal:member_added', added)
      ..event('presence-chat.lobby', 'pusher_internal:member_added', added)
      ..event('presence-chat.lobby', 'pusher_internal:member_removed', {
        'user_id': '1',
      });
    await eventually(() => leaving.isEmpty ? null : true);
    expect(joining, [
      {'id': 3, 'name': 'Citra'},
    ]);
    expect(leaving, [
      {'id': 1, 'name': 'Ana'},
    ]);
    expect(room.members, [
      {'id': 3, 'name': 'Citra'},
    ]);
  });

  test('whispers go out as client- events and come in to listeners', () async {
    final client = echo(
      auth: EchoAuth.custom((_, _) => {'auth': 'app-key:sig'}),
    );
    final typing = <Map<String, Object?>>[];
    final room = client.private('chat.1')
      ..listenForWhisper('typing', typing.add);
    await connected(client);
    await eventually(() => room.subscribed ? true : null);
    room.whisper('typing', {'name': 'Teo'});
    final sent = await server.next((f) => f['event'] == 'client-typing');
    expect(sent['channel'], 'private-chat.1');
    expect(sent['data'], {'name': 'Teo'});
    server.event('private-chat.1', 'client-typing', {'name': 'Ana'});
    await eventually(() => typing.isEmpty ? null : true);
    expect(typing.single, {'name': 'Ana'});
  });

  test('encrypted channels: opened with the shared secret of the '
      'authorization', () async {
    final key = List<int>.generate(32, (i) => i);
    final client = echo(
      auth: EchoAuth.custom(
        (_, _) => {'auth': 'app-key:sig', 'shared_secret': base64.encode(key)},
      ),
    );
    final heard = <Map<String, Object?>>[];
    final channel = client.encryptedPrivate('orders.7')
      ..listen('.secret', heard.add);
    await connected(client);
    final subscribe = await server.next(
      (f) => subscribeTo(f, 'private-encrypted-orders.7'),
    );
    expect((subscribe['data']! as Map).containsKey('shared_secret'), isFalse);
    await eventually(() => channel.subscribed ? true : null);
    final nonce = List<int>.generate(24, (i) => 100 + i);
    final box = Secretbox.seal(utf8.encode('{"code":"4821"}'), nonce, key);
    server.event('private-encrypted-orders.7', 'secret', {
      'ciphertext': base64.encode(box),
      'nonce': base64.encode(nonce),
    });
    // Tampered: dropped, not delivered.
    server.event('private-encrypted-orders.7', 'secret', {
      'ciphertext': base64.encode([...box]..[0] ^= 1),
      'nonce': base64.encode(nonce),
    });
    await eventually(() => heard.isEmpty ? null : true);
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(heard, [
      {'code': '4821'},
    ]);
    expect(() => channel.whisper('x', {}), throwsUnsupportedError);
  });

  test(
    'pings after activity_timeout of silence; answers the server ping',
    () async {
      server.activityTimeout = 1;
      final client = echo();
      await connected(client);
      server.broadcast({'event': 'pusher:ping', 'data': '{}'});
      await server.next((f) => f['event'] == 'pusher:pong');
      await server.next((f) => f['event'] == 'pusher:ping');
    },
  );

  test(
    'a lost connection: reconnects with backoff and subscribes again',
    () async {
      final client = echo();
      final states = <EchoConnectionState>[];
      client.onConnectionStateChange.listen(states.add);
      client.channel('news');
      await connected(client);
      await server.next((f) => subscribeTo(f, 'news'));
      final first = client.socketId;
      await server.drop();
      await server.next((f) => subscribeTo(f, 'news'), skip: 1);
      expect(client.socketId, isNot(first));
      expect(
        states,
        containsAllInOrder([
          EchoConnectionState.unavailable,
          EchoConnectionState.connecting,
          EchoConnectionState.connected,
        ]),
      );
      expect(server.connections, hasLength(2));
    },
  );

  test(
    '4100 (over capacity, a slow client): reconnects after a backoff',
    () async {
      final client = echo(base: const Duration(milliseconds: 150));
      await connected(client);
      final watch = Stopwatch()..start();
      await server.drop(4100);
      await eventually(() => server.connections.length == 2 ? true : null);
      // Half to all of the 150 ms base: not at once, as 4200-4299 would.
      expect(
        watch.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 70)),
      );
      await connected(client);
    },
  );

  test('4200-4299: reconnects at once', () async {
    final client = echo(base: const Duration(seconds: 5));
    await connected(client);
    await server.drop(4200);
    await eventually(() => server.connections.length == 2 ? true : null);
  });

  test('4000-4099: refused for good, no reconnect', () async {
    final client = echo();
    await connected(client);
    await server.drop(4001);
    await eventually(
      () => client.connectionState == EchoConnectionState.disconnected
          ? true
          : null,
    );
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(server.connections, hasLength(1));
  });

  test('leave unsubscribes; disconnect closes', () async {
    final client = echo();
    client.channel('news');
    await connected(client);
    await eventually(() => client.channels['news']!.subscribed ? true : null);
    client.leave('news');
    final unsubscribe = await server.next(
      (f) => f['event'] == 'pusher:unsubscribe',
    );
    expect(unsubscribe['data'], {'channel': 'news'});
    expect(client.channels, isEmpty);
    await client.disconnect();
    expect(client.connectionState, EchoConnectionState.disconnected);
    expect(client.socketId, isNull);
  });
}
