@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel_reverb_client/daravel_reverb_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

import 'fake_pusher.dart';

/// Channel authorizations that finish after their connection changed, that
/// run side by side, or that fail on the way: what is sent, which HTTP
/// clients are made and closed, and where each channel ends.
void main() {
  late FakePusher server;

  setUp(() async => server = await FakePusher.start());
  tearDown(() => server.close());

  Future<T> eventually<T>(T? Function() value, [String what = 'it']) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final v = value();
      if (v != null) {
        return v;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TimeoutException('never: $what');
  }

  Future<void> until(bool Function() done, String what) =>
      eventually(() => done() ? true : null, what);

  /// Long enough for what must not happen (a request, an error, a frame)
  /// to have happened.
  Future<void> settle([int ms = 500]) =>
      Future<void>.delayed(Duration(milliseconds: ms));

  /// Whether a subscription of [channel] is on its way. A channel left
  /// while one is stays (the same object when joined again); otherwise it
  /// is removed, and joining makes another. Ask last: it may leave.
  bool pending(Echo echo, EchoChannel channel) {
    echo.leaveChannel(channel.name);
    final again = echo.private(channel.name.substring('private-'.length));
    return identical(again, channel);
  }

  /// The `auth` of every `pusher:subscribe` the server got for [channel].
  List<Object?> subscribes(String channel) => [
    for (final frame in server.received)
      if (frame['event'] == 'pusher:subscribe' &&
          (frame['data']! as Map<String, Object?>)['channel'] == channel)
        (frame['data']! as Map<String, Object?>)['auth'],
  ];

  group('an authorization that finishes late', () {
    const old = '1.1001';
    const newer = '2.1002';
    const name = 'private-x';
    const lateFailure = EchoAuthException(name, 500, 'late');
    const lateError = {'channel': name, 'status': 500};
    const refusedError = {'channel': name, 'status': 403};

    late Map<String, Completer<Map<String, Object?>>> asked;
    late Echo echo;
    late EchoPrivateChannel channel;
    late List<Map<String, Object?>> errors;
    late List<Object> channelErrors;

    setUp(() {
      asked = {};
      errors = [];
      channelErrors = [];
      echo = Echo.reverb(
        key: 'k',
        host: server.host,
        auth: EchoAuth.custom(
          (socketId, _) => (asked[socketId] = Completer()).future,
        ),
        reconnectBase: const Duration(milliseconds: 5),
        reconnectMax: const Duration(milliseconds: 10),
      );
      echo.onError.listen(errors.add);
      channel = echo.private('x')..error(channelErrors.add);
    });
    tearDown(() => echo.disconnect());

    Future<void> authorizing(String socketId) =>
        until(() => asked.containsKey(socketId), 'authorizing for $socketId');

    Future<void> reconnected() async {
      await authorizing(old);
      await server.drop(4200);
      await authorizing(newer);
    }

    // Each row: the connection when the old authorization finishes, how to
    // get there, and what holds afterwards whether it fails or succeeds: a
    // connection that is not the one authorized for reports nothing.
    final rows =
        <
          ({
            String connection,
            Future<void> Function() arrange,
            bool pending,
            bool subscribed,
            List<Map<String, Object?>> errorsBefore,
            List<Object?> subscribes,
          })
        >[
          (
            connection: 'a newer connection, already subscribed',
            arrange: () async {
              await reconnected();
              asked[newer]!.complete({'auth': 'k:new'});
              await until(() => channel.subscribed, 'subscribed');
            },
            pending: false,
            subscribed: true,
            errorsBefore: [],
            subscribes: ['k:new'],
          ),
          (
            connection: 'a newer connection, still authorizing',
            arrange: reconnected,
            pending: true,
            subscribed: false,
            errorsBefore: [],
            subscribes: [],
          ),
          (
            connection: 'a newer connection whose authorization failed',
            arrange: () async {
              await reconnected();
              asked[newer]!.completeError(
                const EchoAuthException(name, 403, 'refused'),
              );
              await until(() => errors.isNotEmpty, 'the refusal');
            },
            pending: false,
            subscribed: false,
            errorsBefore: [refusedError],
            subscribes: [],
          ),
          (
            connection: 'none, after disconnect()',
            arrange: () async {
              await authorizing(old);
              await echo.disconnect();
            },
            pending: false,
            subscribed: false,
            errorsBefore: [],
            subscribes: [],
          ),
          (
            connection: 'none, after a lost connection',
            arrange: () async {
              await authorizing(old);
              await server.drop(4001);
              await until(
                () => echo.connectionState == EchoConnectionState.disconnected,
                'disconnected',
              );
            },
            pending: false,
            subscribed: false,
            errorsBefore: [],
            subscribes: [],
          ),
          (
            connection: 'connected, with no socket id',
            arrange: () async {
              await authorizing(old);
              server.broadcast({
                'event': 'pusher:connection_established',
                'data': '{}',
              });
              await until(() => echo.socketId == null, 'no socket id');
            },
            pending: false,
            subscribed: false,
            errorsBefore: [],
            subscribes: [],
          ),
        ];

    for (final row in rows) {
      for (final fails in [true, false]) {
        test('${row.connection}: the old one '
            '${fails ? 'fails' : 'succeeds'}', () async {
          await row.arrange();
          if (fails) {
            asked[old]!.completeError(lateFailure);
          } else {
            asked[old]!.complete({'auth': 'k:old'});
          }
          await settle();

          final reported = row.errorsBefore;
          expect(errors, reported, reason: 'Echo.onError');
          expect(channelErrors, hasLength(reported.length));
          expect(channel.subscribed, row.subscribed, reason: 'subscribed');
          expect(subscribes(name), row.subscribes, reason: 'subscribes sent');
          if (row.pending) {
            // The newer authorization still owns the subscription, and
            // finishes it.
            expect(pending(echo, channel), isTrue, reason: 'pending');
            asked[newer]!.complete({'auth': 'k:new'});
            await until(() => channel.subscribed, 'subscribed');
            expect(subscribes(name), ['k:new']);
            expect(errors, reported);
          }
          expect(pending(echo, channel), isFalse, reason: 'pending');
        });
      }
    }

    test('the same connection: the authorization fails', () async {
      await authorizing(old);
      asked[old]!.completeError(lateFailure);
      await settle();
      expect(errors, [lateError]);
      expect(channelErrors, [lateFailure]);
      expect(channel.subscribed, isFalse);
      expect(subscribes(name), isEmpty);
      expect(pending(echo, channel), isFalse);
    });

    test('the same connection: the authorization succeeds', () async {
      await authorizing(old);
      asked[old]!.complete({'auth': 'k:old'});
      await until(() => channel.subscribed, 'subscribed');
      expect(errors, isEmpty);
      expect(channelErrors, isEmpty);
      expect(subscribes(name), ['k:old']);
      expect(pending(echo, channel), isFalse);
    });

    test('after disconnect() and connect() the channel subscribes on the new '
        'connection, whatever the old authorization does', () async {
      await authorizing(old);
      await echo.disconnect();
      echo.connect();
      await authorizing(newer);
      asked[old]!.complete({'auth': 'k:old'});
      await settle();
      expect(channel.subscribed, isFalse);
      expect(subscribes(name), isEmpty);
      asked[newer]!.complete({'auth': 'k:new'});
      await until(() => channel.subscribed, 'subscribed');
      expect(subscribes(name), ['k:new']);
      expect(errors, isEmpty);
    });

    // A channel left while it is authorizing is only marked, and dropped
    // once that ends; with no connection left nothing else would drop it.
    for (final (how, gone, answer) in [
      ('disconnect(), then it fails', 'closed', 'fails'),
      ('disconnect(), then it succeeds', 'closed', 'succeeds'),
      ('a lost connection, then it fails', 'lost', 'fails'),
    ]) {
      test('left while authorizing, $how: the channel is gone', () async {
        await authorizing(old);
        echo.leaveChannel(name);
        if (gone == 'closed') {
          await echo.disconnect();
        } else {
          // 4001: no reconnect follows.
          await server.drop(4001);
          await until(
            () => echo.connectionState == EchoConnectionState.disconnected,
            'disconnected',
          );
        }
        if (answer == 'fails') {
          asked[old]!.completeError(lateFailure);
        } else {
          asked[old]!.complete({'auth': 'k:old'});
        }
        await settle();

        expect(errors, isEmpty);
        expect(channelErrors, isEmpty);
        expect(echo.channels, isEmpty);
        // Joined again it is another channel, not the one left.
        expect(echo.private('x'), isNot(same(channel)));
        expect(channel.subscribed, isFalse);
        expect(
          server.received.where(
            (frame) =>
                frame['event'] == 'pusher:subscribe' ||
                frame['event'] == 'pusher:unsubscribe',
          ),
          isEmpty,
        );
      });
    }
  });

  test('disconnect() leaves no channel subscribed or pending', () async {
    final echo = Echo.reverb(key: 'k', host: server.host);
    addTearDown(echo.disconnect);
    final news = echo.channel('news');
    await eventually(() => news.subscribed ? true : null, 'subscribed');
    await echo.disconnect();
    expect(news.subscribed, isFalse);
  });

  group('the HTTP clients of EchoAuth.bearer', () {
    /// Runs [body] with every `http.Client()` counted in [made].
    Future<void> counting(
      List<_SpyClient> made,
      Future<void> Function() body,
    ) => http.runWithClient(body, () {
      final client = _SpyClient();
      made.add(client);
      addTearDown(client.close);
      return client;
    });

    Matcher refused(Object message) => isA<EchoAuthException>()
        .having((e) => e.status, 'status', 0)
        .having((e) => e.message, 'message', message);

    test('disconnect() while a request is on its way: none follows, every '
        'client is closed, nothing is reported, the channel is not '
        'pending', () async {
      final endpoint = await _HeldEndpoint.start();
      addTearDown(endpoint.close);

      final made = <_SpyClient>[];
      await counting(made, () async {
        final echo = Echo.reverb(
          key: 'k',
          host: server.host,
          auth: EchoAuth.bearer(() => 't', endpoint: endpoint.url),
        );
        addTearDown(echo.disconnect);
        final errors = <Map<String, Object?>>[];
        echo.onError.listen(errors.add);
        final channel = echo.private('a');
        await until(() => endpoint.requests.length == 1, 'the request');
        expect(endpoint.answered, 0);

        await echo.disconnect();
        expect(made, hasLength(1));
        expect(made.every((client) => client.closed), isTrue);
        await settle();

        expect(endpoint.requests, hasLength(1));
        expect(made, hasLength(1));
        expect(errors, isEmpty);
        expect(channel.subscribed, isFalse);
        expect(pending(echo, channel), isFalse);
      });
    });

    test('disconnect() while the token is awaited: no request, no client '
        'left open, nothing is reported, the channel is not '
        'pending', () async {
      final endpoint = await _HeldEndpoint.start(hold: (_) => false);
      addTearDown(endpoint.close);

      final made = <_SpyClient>[];
      final asked = Completer<void>();
      final token = Completer<String>();
      await counting(made, () async {
        final echo = Echo.reverb(
          key: 'k',
          host: server.host,
          auth: EchoAuth.bearer(() {
            asked.complete();
            return token.future;
          }, endpoint: endpoint.url),
        );
        addTearDown(echo.disconnect);
        final errors = <Map<String, Object?>>[];
        echo.onError.listen(errors.add);
        final channel = echo.private('a');
        await asked.future;
        await echo.disconnect();
        token.complete('t');
        await settle();

        expect(endpoint.requests, isEmpty);
        expect(made.every((client) => client.closed), isTrue);
        expect(errors, isEmpty);
        expect(pending(echo, channel), isFalse);
      });
    });

    test('disconnect() while a second request is on its way: its client is '
        'closed at once, nothing is reported, the channel is not '
        'pending', () async {
      var posts = 0;
      final endpoint = await _rawEndpoint((socket, form) {
        if (++posts == 1) {
          socket.destroy();
        }
        // The second request is never answered.
      });
      addTearDown(endpoint.close);

      final made = <_SpyClient>[];
      await counting(made, () async {
        final echo = Echo.reverb(
          key: 'k',
          host: server.host,
          auth: EchoAuth.bearer(
            () => 't',
            endpoint: 'http://127.0.0.1:${endpoint.port}/broadcasting/auth',
          ),
        );
        addTearDown(echo.disconnect);
        final errors = <Map<String, Object?>>[];
        echo.onError.listen(errors.add);
        final channel = echo.private('a');
        await until(() => posts == 2, 'the second request');
        expect(made, hasLength(2));
        expect(made[1].closed, isFalse);

        await echo.disconnect();
        expect(made.where((client) => !client.closed), isEmpty);
        await settle();

        expect(posts, 2);
        expect(made, hasLength(2));
        expect(errors, isEmpty);
        expect(pending(echo, channel), isFalse);
      });
    });

    test('three channels at once, one on a dead socket: only that one asks '
        'again, on a client of its own, and all three subscribe', () async {
      final posts = <String, int>{};
      final allAsked = Completer<void>();
      final release = Completer<void>();
      final endpoint = await _rawEndpoint((socket, form) async {
        final channel = form['channel_name']!;
        final count = posts[channel] = (posts[channel] ?? 0) + 1;
        if (posts.length == 3 && !allAsked.isCompleted) {
          allAsked.complete();
        }
        if (channel == 'private-a' && count == 1) {
          await allAsked.future;
          socket.destroy();
          return;
        }
        if (channel == 'private-a') {
          _respond(socket, '{"auth":"k:a"}');
          if (!release.isCompleted) {
            release.complete();
          }
          return;
        }
        // The others answer once the first has failed and asked again.
        await release.future;
        _respond(socket, '{"auth":"k:other"}');
      });
      addTearDown(endpoint.close);

      final made = <_SpyClient>[];
      await counting(made, () async {
        final echo = Echo.reverb(
          key: 'k',
          host: server.host,
          auth: EchoAuth.bearer(
            () => 't',
            endpoint: 'http://127.0.0.1:${endpoint.port}/broadcasting/auth',
          ),
        );
        addTearDown(echo.disconnect);
        final errors = <Map<String, Object?>>[];
        echo.onError.listen(errors.add);
        final channels = [
          for (final name in 'abc'.split('')) echo.private(name),
        ];
        await until(
          () => channels.every((c) => c.subscribed) || errors.isNotEmpty,
          'all three subscribed',
        );
        await settle();

        expect(errors, isEmpty);
        expect(channels.every((c) => c.subscribed), isTrue);
        expect(posts, {'private-a': 2, 'private-b': 1, 'private-c': 1});
        // The shared client stays open; the one made for the second
        // request is closed.
        expect(made, hasLength(2));
        expect(made[0].closed, isFalse);
        expect(made[1].sent, 1);
        expect(made[1].closed, isTrue);
      });
    });

    test('a lost connection: the authorizations of its socket id are not '
        'asked again and report nothing; the channels subscribe on the next '
        'connection', () async {
      final endpoint = await _HeldEndpoint.start(
        hold: (form) => form['socket_id'] == '1.1001',
      );
      addTearDown(endpoint.close);

      final made = <_SpyClient>[];
      await counting(made, () async {
        final echo = Echo.reverb(
          key: 'k',
          host: server.host,
          auth: EchoAuth.bearer(() => 't', endpoint: endpoint.url),
          reconnectBase: const Duration(milliseconds: 5),
          reconnectMax: const Duration(milliseconds: 10),
        );
        addTearDown(echo.disconnect);
        final errors = <Map<String, Object?>>[];
        final channelErrors = <Object>[];
        echo.onError.listen(errors.add);
        final channels = [
          for (final name in 'abc'.split(''))
            echo.private(name)..error(channelErrors.add),
        ];
        await until(() => endpoint.requests.length == 3, 'three requests');
        expect(endpoint.answered, 0);

        await server.drop(4200);
        await until(
          () =>
              echo.socketId == '2.1002' && channels.every((c) => c.subscribed),
          'subscribed again',
        );
        await settle();

        expect(endpoint.count, {
          for (final socketId in ['1.1001', '2.1002'])
            for (final name in 'abc'.split('')) '$socketId private-$name': 1,
        });
        expect(errors, isEmpty);
        expect(channelErrors, isEmpty);
        expect(channels.every((c) => c.subscribed), isTrue);
        await echo.disconnect();
        expect(made.every((client) => client.closed), isTrue);
      });
    });

    test('an authorization still awaiting its token when the connection is '
        'replaced sends nothing and leaves the new one alone', () async {
      final endpoint = await _HeldEndpoint.start();
      addTearDown(endpoint.close);

      var tokens = 0;
      final oldToken = Completer<String>();
      final made = <_SpyClient>[];
      await counting(made, () async {
        final echo = Echo.reverb(
          key: 'k',
          host: server.host,
          auth: EchoAuth.bearer(
            // The first connection's two authorizations wait; later ones
            // have their token at once.
            () => ++tokens <= 2 ? oldToken.future : 't',
            endpoint: endpoint.url,
          ),
          reconnectBase: const Duration(milliseconds: 5),
          reconnectMax: const Duration(milliseconds: 10),
        );
        addTearDown(echo.disconnect);
        final errors = <Map<String, Object?>>[];
        echo.onError.listen(errors.add);
        final channels = [echo.private('a'), echo.private('b')];
        await until(() => tokens == 2, 'two tokens asked');
        await server.drop(4200);
        await until(() => endpoint.requests.length == 2, 'the new requests');
        expect(endpoint.answered, 0);

        oldToken.complete('t');
        await settle();
        expect(endpoint.count, {'2.1002 private-a': 1, '2.1002 private-b': 1});
        expect(made, hasLength(1));
        expect(made.single.closed, isFalse);

        endpoint.release();
        await until(
          () => channels.every((c) => c.subscribed) || errors.isNotEmpty,
          'subscribed',
        );
        expect(errors, isEmpty);
        expect(channels.every((c) => c.subscribed), isTrue);
        expect(endpoint.requests, hasLength(2));
      });
    });

    group('two Echo instances on one authorizer: one loses its '
        'connection', () {
      /// Closes the first connection the server got, for good (4001).
      Future<void> lose(Echo first) async {
        await server.sockets.first.close(4001);
        await until(
          () => first.connectionState == EchoConnectionState.disconnected,
          'the first disconnected',
        );
      }

      Future<String> connected(Echo echo) =>
          eventually(() => echo.socketId, 'connected');

      test('while the other awaits its token: the other subscribes', () async {
        final endpoint = await _HeldEndpoint.start(hold: (_) => false);
        addTearDown(endpoint.close);

        final asked = Completer<void>();
        final token = Completer<String>();
        final made = <_SpyClient>[];
        await counting(made, () async {
          final auth = EchoAuth.bearer(() {
            asked.complete();
            return token.future;
          }, endpoint: endpoint.url);
          final first = Echo.reverb(key: 'k', host: server.host, auth: auth);
          addTearDown(first.disconnect);
          final firstId = await connected(first);
          final other = Echo.reverb(key: 'k', host: server.host, auth: auth);
          addTearDown(other.disconnect);
          final errors = <Map<String, Object?>>[];
          other.onError.listen(errors.add);
          final channel = other.private('b');
          await asked.future;
          final otherId = other.socketId!;
          expect(endpoint.requests, isEmpty);

          await lose(first);
          token.complete('t');
          await until(
            () => channel.subscribed || errors.isNotEmpty,
            'the other subscribed',
          );
          await settle();

          expect(errors, isEmpty);
          expect(channel.subscribed, isTrue);
          expect(endpoint.count, {'$otherId private-b': 1});
          expect(firstId, isNot(otherId));
        });
      });

      test('while the other has a request on the shared client: the other '
          'asks again and subscribes; the lost one asks no more', () async {
        // The first request of each authorization is held.
        final seen = <String>{};
        final endpoint = await _HeldEndpoint.start(
          hold: (form) =>
              seen.add('${form['socket_id']} ${form['channel_name']}'),
        );
        addTearDown(endpoint.close);

        final made = <_SpyClient>[];
        await counting(made, () async {
          final auth = EchoAuth.bearer(() => 't', endpoint: endpoint.url);
          final first = Echo.reverb(key: 'k', host: server.host, auth: auth);
          addTearDown(first.disconnect);
          final firstErrors = <Map<String, Object?>>[];
          first.onError.listen(firstErrors.add);
          final firstId = await connected(first);
          first.private('a');
          await until(() => endpoint.requests.length == 1, 'its request');

          final other = Echo.reverb(key: 'k', host: server.host, auth: auth);
          addTearDown(other.disconnect);
          final errors = <Map<String, Object?>>[];
          other.onError.listen(errors.add);
          final channel = other.private('b');
          await until(() => endpoint.requests.length == 2, 'both requests');
          final otherId = other.socketId!;
          expect(endpoint.answered, 0);

          await lose(first);
          await until(
            () => channel.subscribed || errors.isNotEmpty,
            'the other subscribed',
          );
          await settle();

          expect(errors, isEmpty);
          expect(firstErrors, isEmpty);
          expect(channel.subscribed, isTrue);
          expect(endpoint.count['$otherId private-b'], 2);
          expect(endpoint.count['$firstId private-a'], 1);
          expect(endpoint.count, hasLength(2));
        });
      });
    });

    test('a request that fails before any answer is sent again once, on a '
        'client made for it and closed; the token is asked once', () async {
      var posts = 0;
      final endpoint = await _rawEndpoint((socket, form) {
        if (++posts == 1) {
          socket.destroy();
        } else {
          _respond(socket, '{"auth":"k:second"}');
        }
      });
      addTearDown(endpoint.close);

      var tokens = 0;
      final made = <_SpyClient>[];
      await counting(made, () async {
        final auth = EchoAuth.bearer(() {
          tokens++;
          return 't';
        }, endpoint: 'http://127.0.0.1:${endpoint.port}/broadcasting/auth');
        expect(
          await auth.authorize('1.1', 'private-orders'),
          containsPair('auth', 'k:second'),
        );
        expect(posts, 2);
        expect(tokens, 1);
        expect(made, hasLength(2));
        expect(made[0].closed, isFalse);
        expect(made[1].closed, isTrue);
      });
    });

    test('a client the application gives is asked once', () async {
      var sent = 0;
      final auth = EchoAuth.bearer(
        () => 't',
        endpoint: 'http://127.0.0.1:9/broadcasting/auth',
        client: MockClient((request) {
          sent++;
          throw http.ClientException('network down', request.url);
        }),
      );
      await expectLater(
        auth.authorize('1.1', 'private-orders'),
        throwsA(refused(contains('network down'))),
      );
      expect(sent, 1);
    });

    for (final status in ['200 OK', '403 Forbidden']) {
      test('an answer of $status whose body is cut off is not asked '
          'again', () async {
        var posts = 0;
        final endpoint = await _rawEndpoint((socket, form) async {
          posts++;
          socket.write(
            'HTTP/1.1 $status\r\n'
            'Content-Type: application/json\r\n'
            'Content-Length: 50\r\n'
            'Connection: close\r\n'
            '\r\n'
            '{"auth":',
          );
          await socket.flush();
          socket.destroy();
        });
        addTearDown(endpoint.close);

        var tokens = 0;
        final made = <_SpyClient>[];
        await counting(made, () async {
          final auth = EchoAuth.bearer(() {
            tokens++;
            return 't';
          }, endpoint: 'http://127.0.0.1:${endpoint.port}/broadcasting/auth');
          await expectLater(
            auth.authorize('1.1', 'private-orders'),
            throwsA(refused(anything)),
          );
          await settle();
          expect(posts, 1);
          expect(tokens, 1);
          expect(made, hasLength(1));
        });
      });
    }

    test('both requests share one timeout', () async {
      const timeout = Duration(seconds: 2);
      var posts = 0;
      final failFirst = Completer<void>();
      final endpoint = await _rawEndpoint((socket, form) async {
        if (++posts == 1) {
          await failFirst.future;
          socket.destroy();
        }
        // The second request is never answered.
      });
      addTearDown(endpoint.close);

      final made = <_SpyClient>[];
      await counting(made, () async {
        final auth = EchoAuth.endpoint(
          'http://127.0.0.1:${endpoint.port}/broadcasting/auth',
          timeout: timeout,
        );
        final watch = Stopwatch()..start();
        final result = expectLater(
          auth.authorize('1.1', 'private-orders'),
          throwsA(refused('timeout')),
        );
        await until(() => posts == 1, 'the first request');
        // The first request fails with most of the timeout spent: a
        // timeout of its own for the second would end well after
        // timeout + 50 %.
        await Future<void>.delayed(timeout * 0.6 - watch.elapsed);
        failFirst.complete();
        await result;

        expect(watch.elapsed, lessThan(timeout * 1.5));
        expect(posts, 2);
        expect(made, hasLength(2));
        expect(made[1].closed, isTrue);
      });
    });

    test('a response that arrives after the timeout is read and '
        'discarded', () async {
      final sending = Completer<http.StreamedResponse>();
      final body = StreamController<List<int>>();
      final auth = EchoAuth.endpoint(
        'http://127.0.0.1:9/broadcasting/auth',
        client: _LateClient(sending.future),
        timeout: const Duration(milliseconds: 100),
      );
      await expectLater(
        auth.authorize('1.1', 'private-orders'),
        throwsA(refused('timeout')),
      );
      expect(body.hasListener, isFalse);

      sending.complete(http.StreamedResponse(body.stream, 200));
      await until(() => body.hasListener, 'the late response read');
      // Its failure is nobody's any more.
      body.addError(http.ClientException('cut off'));
      await body.close();
    });
  });
}

/// A client whose one answer comes when the test gives it.
final class _LateClient extends http.BaseClient {
  _LateClient(this._answer);

  final Future<http.StreamedResponse> _answer;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) => _answer;
}

/// An auth endpoint that records every request and answers `{"auth": ...}`:
/// at once, or, for a request [hold] says to keep (every one by default),
/// when the test calls [release].
final class _HeldEndpoint {
  _HeldEndpoint._(this._server, this._hold);

  static Future<_HeldEndpoint> start({
    bool Function(Map<String, String> form)? hold,
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final endpoint = _HeldEndpoint._(server, hold ?? (_) => true);
    server.listen(endpoint._handle);
    return endpoint;
  }

  final HttpServer _server;
  final bool Function(Map<String, String> form) _hold;
  final Completer<void> _released = Completer<void>();

  /// The forms of the requests received, in order.
  final List<Map<String, String>> requests = [];

  /// How many requests were answered.
  int answered = 0;

  String get url => 'http://127.0.0.1:${_server.port}/broadcasting/auth';

  /// The requests received, counted by `<socket id> <channel>`.
  Map<String, int> get count {
    final count = <String, int>{};
    for (final form in requests) {
      final key = '${form['socket_id']} ${form['channel_name']}';
      count[key] = (count[key] ?? 0) + 1;
    }
    return count;
  }

  /// Answers the requests held, and those still to come.
  void release() {
    if (!_released.isCompleted) {
      _released.complete();
    }
  }

  Future<void> close() {
    release();
    return _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final form = Uri.splitQueryString(await utf8.decodeStream(request));
    requests.add(form);
    if (_hold(form)) {
      await _released.future;
    }
    try {
      request.response
        ..headers.contentType = ContentType.json
        ..write('{"auth":"k:s"}');
      await request.response.close();
      answered++;
    } on Object {
      // The client went away.
    }
  }
}

/// A client that counts what it sends and whether it was closed.
final class _SpyClient extends http.BaseClient {
  final http.Client _inner = IOClient();
  int sent = 0;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    sent++;
    return _inner.send(request);
  }

  @override
  void close() {
    closed = true;
    _inner.close();
  }
}

/// An HTTP endpoint on a bare socket: [onPost] gets each request's socket
/// and form, and answers it, cuts it off or leaves it, as a test needs.
Future<ServerSocket> _rawEndpoint(
  FutureOr<void> Function(Socket socket, Map<String, String> form) onPost,
) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((socket) {
    final buffer = <int>[];
    socket.done.ignore();
    socket.listen((chunk) async {
      buffer.addAll(chunk);
      final text = latin1.decode(buffer);
      final end = text.indexOf('\r\n\r\n');
      if (end < 0) {
        return;
      }
      final length = int.parse(
        RegExp(
              r'content-length:\s*(\d+)',
              caseSensitive: false,
            ).firstMatch(text.substring(0, end))?.group(1) ??
            '0',
      );
      if (buffer.length < end + 4 + length) {
        return;
      }
      final form = Uri.splitQueryString(
        text.substring(end + 4, end + 4 + length),
      );
      buffer.clear();
      try {
        await onPost(socket, form);
      } on Object {
        // The client went away, or the test ended.
      }
    }, onError: (Object _) {});
  });
  return server;
}

/// Answers 200 with [body] and closes the connection.
void _respond(Socket socket, String body) {
  socket.write(
    'HTTP/1.1 200 OK\r\n'
    'Content-Type: application/json\r\n'
    'Content-Length: ${body.length}\r\n'
    'Connection: close\r\n'
    '\r\n'
    '$body',
  );
  socket.close().ignore();
}
