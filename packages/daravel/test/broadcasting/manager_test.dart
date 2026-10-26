import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Viewer implements Authenticatable {
  const Viewer(this.id);
  final int id;
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

void main() {
  test('the reverb driver posts signed events, as pusher-php-server', () async {
    final factory = HttpClientFactory();
    final http = factory.fake({
      'reverb.test/*': Http.response(<String, Object?>{}),
    });
    final manager = BroadcastManager(
      const BroadcastConfig(
        connection: 'reverb',
        appId: '7',
        appKey: 'key',
        appSecret: 'secret',
        host: 'reverb.test',
        port: 8080,
        scheme: 'http',
      ),
      http: factory,
    );
    await manager.send(
      'App\\Events\\Shipped',
      ['private-orders.7'],
      {'id': 7},
      exceptSocket: '1.2',
    );

    http.assertSentCount(1);
    final request = http.recorded.single;
    expect(request.method, 'POST');
    expect(
      request.url.toString(),
      startsWith('http://reverb.test:8080/apps/7/events?'),
    );
    final body = request.body;
    expect(jsonDecode(body), {
      'name': r'App\Events\Shipped',
      'data': '{"id":7}',
      'channels': ['private-orders.7'],
      'socket_id': '1.2',
    });
    // The receiving server (Reverb or Daravel) accepts the signature.
    expect(
      PusherSignature.verifyRequest(
        secret: 'secret',
        method: 'POST',
        path: '/apps/7/events',
        query: request.url.queryParameters,
        body: body,
      ),
      isTrue,
    );
  });

  test('pusher builds its host from the cluster; log and null drop', () async {
    final pusher = BroadcastConfig.fromEnv(
      Env.fromMap(const {
        'BROADCAST_CONNECTION': 'pusher',
        'PUSHER_APP_ID': '1',
        'PUSHER_APP_KEY': 'k',
        'PUSHER_APP_SECRET': 's',
        'PUSHER_APP_CLUSTER': 'ap1',
      }),
    );
    expect(pusher.host, 'api-ap1.pusher.com');
    expect(pusher.port, 443);
    expect(pusher.appKey, 'k');

    final reverb = BroadcastConfig.fromEnv(
      Env.fromMap(const {
        'REVERB_APP_ID': '1',
        'REVERB_APP_KEY': 'k',
        'REVERB_APP_SECRET': 's',
      }),
    );
    expect(reverb.connection, 'daravel');
    expect(reverb.serves, isTrue);

    final logger = Logger(minimumLevel: LogLevel.debug);
    await BroadcastManager(
      const BroadcastConfig(connection: 'log'),
      logger: logger,
    ).send('x', ['a'], {'n': 1});
    await BroadcastManager(const BroadcastConfig(connection: 'null'))
        .send('x', ['a'], {'n': 1});
    expect(
      () => BroadcastManager(const BroadcastConfig()).send('x', ['a'], 1),
      throwsStateError,
    );
  });

  test('channel patterns match as Laravel\'s, prefix removed', () async {
    final channels = ChannelRegistry()
      ..channel('orders.{id}', (user, p) => p['id'] == '7')
      ..channel(
        'chat.{room}.{thread}',
        (user, p) => {'room': p['room'], 'thread': p['thread']},
      )
      ..channel('denied.{x}', (user, p) => false)
      ..channel('denied.{x}', (user, p) => true);
    const user = Viewer(1);
    expect(await channels.authorize(user, 'private-orders.7'), isTrue);
    expect(await channels.authorize(user, 'private-orders.8'), isNull);
    // A placeholder stops at a dot.
    expect(await channels.authorize(user, 'private-orders.7.8'), isNull);
    expect(await channels.authorize(user, 'presence-chat.a.b'), {
      'room': 'a',
      'thread': 'b',
    });
    // false stops at the first match, as in Laravel.
    expect(await channels.authorize(user, 'private-denied.1'), isNull);
    expect(ChannelRegistry.normalize('private-encrypted-x'), 'x');
  });

  test('channel membership counts users, not connections', () {
    final service = ChannelMembershipService();
    Map<Object?, Object?> join(String socket, String? user) =>
        service.handle('join', {
              'channel': 'presence-room',
              'socket': socket,
              'user_id': user,
              'user_info': user == null ? null : {'name': 'u$user'},
            })!
            as Map;
    Map<Object?, Object?> leave(String socket) =>
        service.handle('leave', {'channel': 'presence-room', 'socket': socket})!
            as Map;

    expect(join('1.1', '1')['added'], isTrue);
    expect(join('1.2', '1')['added'], isFalse);
    expect(join('2.1', '2')['members'], {
      '1': {'name': 'u1'},
      '2': {'name': 'u2'},
    });
    expect(leave('1.1')['removed'], isNull);
    expect(leave('1.2')['removed'], '1');
    expect(service.handle('users', {'channel': 'presence-room'}), ['2']);
    expect(leave('2.1')['removed'], '2');
    expect(service.handle('channel', {'channel': 'presence-room'}), {
      'occupied': false,
      'subscription_count': 0,
      'user_count': 0,
    });
  });
}
