import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Coordinator failures (a timeout, a full queue) in the middle of
/// broadcasting: nothing may be left in a state it never recovers from
/// (#151).
void main() {
  late Coordinator coordinator;
  late _FaultyChannel channel;
  late Broadcaster broadcaster;

  setUp(() {
    coordinator = createStandardCoordinator();
    channel = _FaultyChannel(LocalCoordinatorChannel(coordinator));
    broadcaster = Broadcaster(channel);
  });

  tearDown(() => broadcaster.close());

  Map<String, Object?> broadcastStats() =>
      coordinator.service('broadcast')!.stats();

  group('Broadcaster', () {
    test('a failed subscribe does not poison the channel', () async {
      channel.failNext('broadcast', 'subscribe');
      await expectLater(
        broadcaster.subscribe('news'),
        throwsA(isA<CoordinatorTimeoutException>()),
      );
      final subscription = await broadcaster.subscribe('news');
      final received = <String>[];
      subscription.messages.listen(received.add);
      expect(await broadcaster.publish('news', 'hello'), 1);
      await pumpEventQueue();
      expect(received, ['hello']);
      await subscription.cancel();
      expect(broadcastStats()['channels'], 0);
    });

    test('a failed unsubscribe is retried by the next stray message', () async {
      final subscription = await broadcaster.subscribe('news');
      subscription.messages.listen((_) {});
      channel.failNext('broadcast', 'unsubscribe');
      await subscription.cancel(); // does not throw
      expect(broadcastStats()['channels'], 1, reason: 'still registered');
      // Nobody listens here any more: the message unsubscribes again.
      expect(await broadcaster.publish('news', 'stray'), 1);
      await pumpEventQueue();
      expect(broadcastStats()['channels'], 0);
      expect(await broadcaster.publish('news', 'nobody'), 0);
    });
  });

  group('PusherServer', () {
    late HttpServer http;
    late PusherServer pusher;
    late _FlakyRelay relay;
    final errors = <String>[];
    final sessions = <Future<void>>[];
    final uncaught = <Object>[];

    /// Each connection in a request scope of its own, as the server runs
    /// it (an error zone per request).
    var inRequestScopes = false;

    setUp(() async {
      errors.clear();
      sessions.clear();
      uncaught.clear();
      inRequestScopes = false;
      relay = _FlakyRelay();
      pusher = PusherServer(
        const BroadcastConfig(appId: '1', appKey: 'key', appSecret: 'secret'),
        broadcaster,
        channel,
        relay: relay,
        onError: (message, _) => errors.add(message),
      );
      http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      http.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        Future<void> serve() =>
            pusher.connect(socket, Request.fake(path: '/app/key'), 'key');
        sessions.add(
          inRequestScopes
              ? Container().runScoped(
                  'request',
                  (_) => serve(),
                  onUncaughtError: (error, _) => uncaught.add(error),
                )
              : serve(),
        );
      });
    });

    tearDown(() => http.close(force: true));

    Future<_Client> connect() async =>
        _Client(await WebSocket.connect('ws://127.0.0.1:${http.port}/app/key'));

    Future<Map<Object?, Object?>> info(String name) async =>
        (await channel.call('channels', 'channel', {'channel': name}))! as Map;

    test('a leave that fails on close does not keep the other channels '
        'subscribed', () async {
      final client = await connect();
      expect((await client.next())['event'], 'pusher:connection_established');
      for (final name in ['a', 'b']) {
        client.subscribe(name);
        expect(
          (await client.next())['event'],
          'pusher_internal:subscription_succeeded',
        );
      }
      // Every leave of `a` fails, the first try and the retry.
      channel.failAlways('channels', 'leave', channel: 'a');
      await client.socket.close();
      await Future.wait(sessions);

      expect((await info('b'))['occupied'], isFalse);
      expect(broadcastStats()['channels'], 0, reason: 'both cancelled');
      expect(errors, ['Connection ${client.socketId} could not leave a']);
    });

    test('a coordinator failure while handling a message closes the socket '
        'with 4100', () async {
      final client = await connect();
      await client.next();
      channel.failNext('channels', 'join');
      client.subscribe('news');
      final error = await client.next();
      expect(error['event'], 'pusher:error');
      expect(jsonDecode(error['data']! as String), {
        'code': 4100,
        'message': 'Over capacity',
      });
      await client.ended;
      expect(client.socket.closeCode, 4100);
      await Future.wait(sessions);
      expect(broadcastStats()['channels'], 0);
    });

    test('a relay that failed to start is started again by the next '
        'client', () async {
      relay.failures = 1;
      final first = await connect();
      final refused = await first.next();
      expect(jsonDecode(refused['data']! as String), {
        'code': 4100,
        'message': 'Over capacity',
      });
      await first.ended;
      expect(first.socket.closeCode, 4100);
      expect(errors, ['Broadcast relay did not start']);

      final second = await connect();
      expect((await second.next())['event'], 'pusher:connection_established');
      expect(relay.starts, 2);
      await second.socket.close();
      await Future.wait(sessions);
    });

    test('a relay that fails to start reaches every connection waiting on '
        'it, each in its own request', () async {
      inRequestScopes = true;
      relay
        ..failures = 1
        ..delay = const Duration(milliseconds: 200);
      // Both arrive while the one start is running.
      final clients = await Future.wait([connect(), connect()]);
      for (final client in clients) {
        final refused = await client.next().timeout(const Duration(seconds: 5));
        expect(jsonDecode(refused['data']! as String), {
          'code': 4100,
          'message': 'Over capacity',
        });
        await client.ended;
      }
      expect(relay.starts, 1, reason: 'one start, shared');
      expect(errors, [
        'Broadcast relay did not start',
        'Broadcast relay did not start',
      ]);
      expect(uncaught, isEmpty);
      await Future.wait(sessions);
    });
  });
}

/// A coordinator channel whose calls fail on demand, as a timeout would.
final class _FaultyChannel implements CoordinatorChannel {
  _FaultyChannel(this._inner);

  final CoordinatorChannel _inner;
  final List<(String, String)> _once = [];
  final List<(String, String, String)> _always = [];

  void failNext(String service, String op) => _once.add((service, op));

  void failAlways(String service, String op, {required String channel}) =>
      _always.add((service, op, channel));

  @override
  StateScope get scope => _inner.scope;

  @override
  bool get isRemote => _inner.isRemote;

  @override
  Future<Object?> call(
    String service,
    String op,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    if (_once.remove((service, op)) ||
        _always.contains((service, op, args['channel']))) {
      throw CoordinatorTimeoutException(service, timeout);
    }
    return _inner.call(service, op, args, timeout: timeout);
  }
}

/// A relay whose first [failures] starts fail, as Redis being down does.
final class _FlakyRelay implements BroadcastRelay {
  int failures = 0;
  int starts = 0;
  Duration delay = Duration.zero;

  @override
  Future<void> start(
    void Function(String channel, String envelope) deliver,
  ) async {
    starts++;
    await Future<void>.delayed(delay);
    if (failures > 0) {
      failures--;
      throw const SocketException('Connection refused');
    }
  }

  @override
  Future<void> send(String channel, String envelope) async {}

  @override
  Future<void> close() async {}
}

final class _Client {
  _Client(this.socket) {
    _reading = socket.listen((message) {
      final frame = jsonDecode(message as String) as Map<String, Object?>;
      if (frame['event'] == 'pusher:connection_established') {
        socketId =
            (jsonDecode(frame['data']! as String) as Map)['socket_id']!
                as String;
      }
      if (_waiting.isNotEmpty) {
        _waiting.removeAt(0).complete(frame);
      } else {
        _frames.add(frame);
      }
    }, onDone: _ended.complete);
  }

  final WebSocket socket;
  late final StreamSubscription<Object?> _reading;
  final List<Map<String, Object?>> _frames = [];
  final List<Completer<Map<String, Object?>>> _waiting = [];
  String? socketId;
  final Completer<void> _ended = Completer<void>();

  /// Completes when the server closed the connection.
  Future<void> get ended => _ended.future;

  Future<Map<String, Object?>> next() {
    if (_frames.isNotEmpty) {
      return Future.value(_frames.removeAt(0));
    }
    final waiting = Completer<Map<String, Object?>>();
    _waiting.add(waiting);
    return waiting.future.timeout(const Duration(seconds: 5));
  }

  void subscribe(String channel) => socket.add(
    jsonEncode({
      'event': 'pusher:subscribe',
      'data': {'channel': channel},
    }),
  );

  Future<void> cancel() => _reading.cancel();
}
