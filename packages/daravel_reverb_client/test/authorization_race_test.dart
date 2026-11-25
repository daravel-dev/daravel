@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel_reverb_client/daravel_reverb_client.dart';
import 'package:daravel_reverb_client/src/auth_support.dart';
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

  Future<void> settle([int ms = 60]) =>
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
    // get there, and what holds afterwards whether it fails or succeeds
    // (unless a cell says otherwise below).
    final rows =
        <
          ({
            String connection,
            Future<void> Function() arrange,
            bool pending,
            bool subscribed,
            List<Map<String, Object?>> errorsBefore,
            bool reportsLateFailure,
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
            reportsLateFailure: false,
            subscribes: ['k:new'],
          ),
          (
            connection: 'a newer connection, still authorizing',
            arrange: reconnected,
            pending: true,
            subscribed: false,
            errorsBefore: [],
            reportsLateFailure: false,
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
            reportsLateFailure: false,
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
            reportsLateFailure: true,
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
            reportsLateFailure: true,
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
            reportsLateFailure: true,
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

          final reported = [
            ...row.errorsBefore,
            if (fails && row.reportsLateFailure) lateError,
          ];
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

    test('disconnect() while a request is on its way: none follows, every '
        'client is closed, the channel is not pending', () async {
      var posts = 0;
      final endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => endpoint.close(force: true));
      endpoint.listen((request) async {
        await utf8.decodeStream(request);
        posts++;
        await Future<void>.delayed(const Duration(milliseconds: 300));
        try {
          request.response.write('{"auth":"k:s"}');
          await request.response.close();
        } on Object {
          // The client went away.
        }
      });

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
        await until(() => posts == 1, 'the request');
        await echo.disconnect();
        await settle(200);

        expect(posts, 1, reason: 'requests');
        expect(made, hasLength(1));
        expect(made.every((client) => client.closed), isTrue);
        expect(errors, [
          {'channel': 'private-a', 'status': 0},
        ]);
        expect(channel.subscribed, isFalse);
        expect(pending(echo, channel), isFalse);
      });
    });

    test('disconnect() while the token is awaited: no request, no client '
        'left open, the channel is not pending', () async {
      var posts = 0;
      final endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => endpoint.close(force: true));
      endpoint.listen((request) async {
        await utf8.decodeStream(request);
        posts++;
        request.response.write('{"auth":"k:s"}');
        await request.response.close();
      });

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
          }, endpoint: 'http://127.0.0.1:${endpoint.port}/broadcasting/auth'),
        );
        addTearDown(echo.disconnect);
        final errors = <Map<String, Object?>>[];
        echo.onError.listen(errors.add);
        final channel = echo.private('a');
        await asked.future;
        await echo.disconnect();
        token.complete('t');
        await settle(200);

        expect(posts, 0, reason: 'requests');
        expect(made.every((client) => client.closed), isTrue);
        expect(errors, [
          {'channel': 'private-a', 'status': 0},
        ]);
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
          await allAsked.future.timeout(const Duration(seconds: 2));
          socket.destroy();
          return;
        }
        if (channel == 'private-a') {
          _respond(socket, '{"auth":"k:a"}');
          await settle();
          if (!release.isCompleted) {
            release.complete();
          }
          return;
        }
        // The others answer once the first has failed and asked again.
        await release.future.timeout(const Duration(seconds: 2));
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
        // The shared client stays open; the one made for the retry is
        // closed.
        expect(made, hasLength(2));
        expect(made[0].closed, isFalse);
        expect(made[1].sent, 1);
        expect(made[1].closed, isTrue);
      });
    });

    test('a lost connection: the authorizations of its socket id are not '
        'asked again', () async {
      final posts = <String, int>{};
      final endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => endpoint.close(force: true));
      endpoint.listen((request) async {
        final form = Uri.splitQueryString(await utf8.decodeStream(request));
        final socketId = form['socket_id']!;
        final key = '$socketId ${form['channel_name']}';
        posts[key] = (posts[key] ?? 0) + 1;
        if (socketId == '1.1001') {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
        try {
          request.response.write('{"auth":"k:s"}');
          await request.response.close();
        } on Object {
          // The client went away.
        }
      });

      final made = <_SpyClient>[];
      await counting(made, () async {
        final echo = Echo.reverb(
          key: 'k',
          host: server.host,
          auth: EchoAuth.bearer(
            () => 't',
            endpoint: 'http://127.0.0.1:${endpoint.port}/broadcasting/auth',
          ),
          reconnectBase: const Duration(milliseconds: 5),
          reconnectMax: const Duration(milliseconds: 10),
        );
        addTearDown(echo.disconnect);
        final channels = [
          for (final name in 'abc'.split('')) echo.private(name),
        ];
        await until(() => posts.length == 3, 'three requests');
        await server.drop(4200);
        await until(
          () =>
              echo.socketId == '2.1002' && channels.every((c) => c.subscribed),
          'subscribed again',
        );
        await settle(400);

        expect(posts, {
          for (final socketId in ['1.1001', '2.1002'])
            for (final name in 'abc'.split('')) '$socketId private-$name': 1,
        });
        expect(channels.every((c) => c.subscribed), isTrue);
        await echo.disconnect();
        expect(made.every((client) => client.closed), isTrue);
      });
    });

    test('an authorization still awaiting its token when the connection is '
        'replaced sends nothing and leaves the new one alone', () async {
      final posts = <String, int>{};
      final endpoint = await _rawEndpoint((socket, form) async {
        final socketId = form['socket_id']!;
        final key = '$socketId ${form['channel_name']}';
        posts[key] = (posts[key] ?? 0) + 1;
        if (socketId == '1.1001') {
          socket.destroy();
          return;
        }
        await settle(250);
        _respond(socket, '{"auth":"k:s"}');
      });
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
            endpoint: 'http://127.0.0.1:${endpoint.port}/broadcasting/auth',
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
        await until(() => posts.length == 2, 'the new requests');
        oldToken.complete('t');
        await until(
          () => channels.every((c) => c.subscribed) || errors.isNotEmpty,
          'subscribed',
        );
        await settle();

        expect(errors, isEmpty);
        expect(channels.every((c) => c.subscribed), isTrue);
        expect(posts, {'2.1002 private-a': 1, '2.1002 private-b': 1});
        expect(made, hasLength(1));
        expect(made.single.closed, isFalse);
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
        (auth as ClosableEchoAuth).close();
        expect(made[0].closed, isTrue);
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
        throwsA(
          isA<EchoAuthException>()
              .having((e) => e.status, 'status', 0)
              .having((e) => e.message, 'message', contains('network down')),
        ),
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
        final auth = EchoAuth.bearer(() {
          tokens++;
          return 't';
        }, endpoint: 'http://127.0.0.1:${endpoint.port}/broadcasting/auth');
        addTearDown((auth as ClosableEchoAuth).close);
        await expectLater(
          auth.authorize('1.1', 'private-orders'),
          throwsA(
            isA<EchoAuthException>().having((e) => e.status, 'status', 0),
          ),
        );
        await settle(100);
        expect(posts, 1);
        expect(tokens, 1);
      });
    }

    test('both attempts share one timeout', () async {
      var posts = 0;
      final endpoint = await _rawEndpoint((socket, form) async {
        if (++posts == 1) {
          await settle(800);
          socket.destroy();
        }
        // The second request is never answered.
      });
      addTearDown(endpoint.close);

      final auth = EchoAuth.endpoint(
        'http://127.0.0.1:${endpoint.port}/broadcasting/auth',
        timeout: const Duration(seconds: 1),
      );
      addTearDown((auth as ClosableEchoAuth).close);
      final watch = Stopwatch()..start();
      await expectLater(
        auth.authorize('1.1', 'private-orders'),
        throwsA(
          isA<EchoAuthException>()
              .having((e) => e.status, 'status', 0)
              .having((e) => e.message, 'message', 'timeout'),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 1500)));
      expect(posts, 2);
    });
  });
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
