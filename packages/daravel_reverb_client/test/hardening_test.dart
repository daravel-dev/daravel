@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';

import 'package:daravel_reverb_client/daravel_reverb_client.dart';
import 'package:daravel_reverb_client/src/secretbox.dart';
import 'package:test/test.dart';

import 'fake_pusher.dart';

/// What a server or the network can do to a client: a reconnect asked for
/// while one is waiting, frames of an encrypted channel that do not open,
/// an `activity_timeout` out of range, a channel left while subscribing,
/// and errors of the socket.
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
    String? host,
    EchoAuth? auth,
    Duration base = const Duration(milliseconds: 20),
    Duration max = const Duration(milliseconds: 200),
  }) {
    final client = Echo.reverb(
      key: 'app-key',
      host: host ?? server.host,
      auth: auth,
      reconnectBase: base,
      reconnectMax: max,
    );
    clients.add(client);
    return client;
  }

  Future<void> state(Echo client, EchoConnectionState wanted) async {
    if (client.connectionState != wanted) {
      await client.onConnectionStateChange
          .firstWhere((s) => s == wanted)
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

  bool frame(Map<String, Object?> f, String event, String channel) =>
      f['event'] == event && (f['data']! as Map)['channel'] == channel;

  test(
    'connect() while a reconnect waits: one socket, each event once',
    () async {
      // The backoff is 300 ms; connect() comes before it.
      final client = echo(
        base: const Duration(milliseconds: 300),
        max: const Duration(milliseconds: 300),
      );
      final heard = <Map<String, Object?>>[];
      client.channel('news').listen('.tick', heard.add);
      await state(client, EchoConnectionState.connected);
      await server.next((f) => frame(f, 'pusher:subscribe', 'news'));
      await server.drop();
      await state(client, EchoConnectionState.unavailable);
      client.connect();
      await state(client, EchoConnectionState.connected);
      await server.next((f) => frame(f, 'pusher:subscribe', 'news'), skip: 1);
      // Past the backoff: the waiting reconnect must not have opened a
      // second socket.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      expect(server.connections, hasLength(2));
      server.event('news', 'tick', {'n': 1});
      await eventually(() => heard.isEmpty ? null : true);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(heard, [
        {'n': 1},
      ]);
    },
  );

  test('a state listener that calls connect() on unavailable: the states '
      'follow in order, nothing throws, and the waiting reconnect does not '
      'replace that connection', () async {
    // A short backoff: the reconnect timer was armed after the state was
    // announced, so connect() inside the listener could not cancel it.
    final client = echo(
      base: const Duration(milliseconds: 150),
      max: const Duration(milliseconds: 150),
    );
    final states = <EchoConnectionState>[];
    client.onConnectionStateChange.listen((state) {
      states.add(state);
      if (state == EchoConnectionState.unavailable) {
        client.connect();
      }
    });
    await state(client, EchoConnectionState.connected);
    await server.drop();
    await eventually(() => server.connections.length == 2 ? true : null);
    await state(client, EchoConnectionState.connected);
    expect(
      states,
      containsAllInOrder([
        EchoConnectionState.unavailable,
        EchoConnectionState.connecting,
        EchoConnectionState.connected,
      ]),
    );
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(server.connections, hasLength(2));
  });

  test('an encrypted frame that does not open is dropped and reported, '
      'not thrown out of the socket listener', () async {
    final key = List<int>.generate(32, (i) => i);
    final client = echo(
      auth: EchoAuth.custom(
        (_, _) => {'auth': 'app-key:sig', 'shared_secret': base64.encode(key)},
      ),
    );
    final heard = <Map<String, Object?>>[];
    final errors = <Map<String, Object?>>[];
    client.onError.listen(errors.add);
    final channel = client.encryptedPrivate('orders.7')
      ..listen('.secret', heard.add);
    await state(client, EchoConnectionState.connected);
    await eventually(() => channel.subscribed ? true : null);
    const name = 'private-encrypted-orders.7';
    final nonce = List<int>.generate(24, (i) => 100 + i);
    for (final data in <Object?>[
      // Not base64.
      {'ciphertext': '%%%', 'nonce': '@@'},
      // A nonce of the wrong length.
      {'ciphertext': base64.encode(List.filled(40, 1)), 'nonce': 'AAAA'},
      // Not an envelope at all.
      'plain text',
      {'ciphertext': 7, 'nonce': null},
      // Opens, but is not UTF-8.
      {
        'ciphertext': base64.encode(Secretbox.seal([0xFF, 0xFE], nonce, key)),
        'nonce': base64.encode(nonce),
      },
    ]) {
      server.event(name, 'secret', data);
    }
    final box = Secretbox.seal(utf8.encode('{"code":"4821"}'), nonce, key);
    server.event(name, 'secret', {
      'ciphertext': base64.encode(box),
      'nonce': base64.encode(nonce),
    });
    await eventually(() => heard.isEmpty ? null : true);
    expect(heard, [
      {'code': '4821'},
    ]);
    expect(errors.where((e) => e['type'] == 'DecryptionError'), hasLength(5));
    expect(errors.first, {
      'type': 'DecryptionError',
      'channel': name,
      'event': 'secret',
    });
  });

  group('activity_timeout from the server', () {
    for (final value in ['0', '-5', '1e400']) {
      test(
        '$value: ignored, the client keeps its own (no ping at once)',
        () async {
          server.activityTimeoutJson = value;
          final client = echo();
          await state(client, EchoConnectionState.connected);
          await Future<void>.delayed(const Duration(milliseconds: 500));
          expect(
            server.received.where((f) => f['event'] == 'pusher:ping'),
            isEmpty,
          );
        },
      );
    }

    test('0.001: at least one second between pings', () async {
      server.activityTimeoutJson = '0.001';
      final client = echo();
      await state(client, EchoConnectionState.connected);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(
        server.received.where((f) => f['event'] == 'pusher:ping'),
        isEmpty,
      );
      await server.next((f) => f['event'] == 'pusher:ping');
    });
  });

  group('leaving while subscribing', () {
    test('after the subscribe was sent: unsubscribed once confirmed, and '
        'no listener told', () async {
      server.confirmDelay = const Duration(milliseconds: 300);
      final client = echo();
      await state(client, EchoConnectionState.connected);
      var told = false;
      client.channel('news').subscribedTo(() => told = true);
      await server.next((f) => frame(f, 'pusher:subscribe', 'news'));
      client.leaveChannel('news');
      expect(client.channels, isNot(contains('news')));
      await server.next((f) => frame(f, 'pusher:unsubscribe', 'news'));
      expect(told, isFalse);
      expect(client.channels, isEmpty);
    });

    test(
      'joined again before the confirmation: the subscription stands',
      () async {
        server.confirmDelay = const Duration(milliseconds: 300);
        final client = echo();
        await state(client, EchoConnectionState.connected);
        final first = client.channel('news');
        await server.next((f) => frame(f, 'pusher:subscribe', 'news'));
        client.leaveChannel('news');
        final again = client.channel('news');
        expect(again, same(first));
        await eventually(() => again.subscribed ? true : null);
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(
          server.received.where((f) => f['event'] == 'pusher:unsubscribe'),
          isEmpty,
        );
        expect(client.channels.keys, ['news']);
      },
    );

    test('before the subscribe was sent: nothing is sent', () async {
      final client = echo();
      await state(client, EchoConnectionState.connected);
      client
        ..channel('news')
        ..leaveChannel('news');
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(
        server.received.where(
          (f) =>
              f['event'] == 'pusher:subscribe' ||
              f['event'] == 'pusher:unsubscribe',
        ),
        isEmpty,
      );
      expect(client.channels, isEmpty);
    });
  });

  test(
    'an error of the socket reaches onError, as pusher-js emits it',
    () async {
      final port = server.port;
      await server.close();
      final client = echo(
        host: 'ws://127.0.0.1:$port',
        base: const Duration(seconds: 5),
        max: const Duration(seconds: 5),
      );
      final error = await client.onError.first.timeout(
        const Duration(seconds: 5),
      );
      expect(error['type'], 'WebSocketError');
      expect(error['error'], isA<String>());
      // setUp's server is closed already; tearDown closes it again.
      server = await FakePusher.start();
    },
  );
}
