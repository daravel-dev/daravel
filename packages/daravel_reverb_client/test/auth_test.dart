@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel_reverb_client/daravel_reverb_client.dart';
import 'package:daravel_reverb_client/src/secretbox.dart';
import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'fake_pusher.dart';

/// What an auth endpoint, or an authorizer of the application's own, can
/// answer, and what the client makes of it.
void main() {
  late HttpServer endpoint;
  // The next answer of [endpoint]: status, body, and a delay.
  var answer = (200, '{"auth":"key:sig"}', Duration.zero);

  setUp(() async {
    answer = (200, '{"auth":"key:sig"}', Duration.zero);
    endpoint = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    endpoint.listen((request) async {
      await utf8.decodeStream(request);
      final (status, body, delay) = answer;
      await Future<void>.delayed(delay);
      request.response
        ..statusCode = status
        ..write(body);
      await request.response.close();
    });
  });

  tearDown(() => endpoint.close(force: true));

  String url() => 'http://127.0.0.1:${endpoint.port}/broadcasting/auth';

  Matcher refused(int status, String message) => isA<EchoAuthException>()
      .having((e) => e.status, 'status', status)
      .having((e) => e.message, 'message', message);

  group('an HTTP endpoint', () {
    test('a 2xx answer that is not JSON: the status, "invalid json"', () async {
      final auth = EchoAuth.endpoint(url());
      for (final body in ['<html>login</html>', '']) {
        answer = (200, body, Duration.zero);
        await expectLater(
          auth.authorize('1.2', 'private-orders'),
          throwsA(refused(200, 'invalid json')),
          reason: body,
        );
      }
    });

    test('auth and channel_data must be strings', () async {
      final auth = EchoAuth.endpoint(url());
      answer = (201, '{"auth":7}', Duration.zero);
      await expectLater(
        auth.authorize('1.2', 'private-orders'),
        throwsA(refused(201, 'no auth')),
      );
      answer = (200, '[1]', Duration.zero);
      await expectLater(
        auth.authorize('1.2', 'private-orders'),
        throwsA(refused(200, 'not a JSON object')),
      );
      answer = (200, '{"auth":"k:s","channel_data":{"id":1}}', Duration.zero);
      await expectLater(
        auth.authorize('1.2', 'presence-room'),
        throwsA(refused(200, 'channel_data is not a string')),
      );
    });

    test('an encrypted channel needs a shared_secret of 32 bytes, refused '
        'with the status the endpoint answered', () async {
      final auth = EchoAuth.endpoint(url());
      for (final (secret, message) in [
        (null, 'no shared_secret'),
        ('%%%', 'shared_secret is not base64'),
        (
          base64.encode(List.filled(16, 1)),
          'shared_secret is 16 bytes, not 32',
        ),
      ]) {
        answer = (
          200,
          jsonEncode({'auth': 'k:s', 'shared_secret': ?secret}),
          Duration.zero,
        );
        await expectLater(
          auth.authorize('1.2', 'private-encrypted-orders'),
          throwsA(refused(200, message)),
          reason: message,
        );
      }
      answer = (
        200,
        jsonEncode({
          'auth': 'k:s',
          'shared_secret': base64.encode(List.filled(32, 1)),
        }),
        Duration.zero,
      );
      expect(
        await auth.authorize('1.2', 'private-encrypted-orders'),
        containsPair('auth', 'k:s'),
      );
    });

    test('an answer slower than the timeout: status 0, "timeout"', () async {
      answer = (200, '{"auth":"k:s"}', const Duration(milliseconds: 600));
      final auth = EchoAuth.endpoint(
        url(),
        timeout: const Duration(milliseconds: 100),
      );
      await expectLater(
        auth.authorize('1.2', 'private-orders'),
        throwsA(refused(0, 'timeout')),
      );
    });

    test("a client the application gives is used and not closed; the "
        "client's own is closed by disconnect and made again", () async {
      final given = _CountingClient();
      final auth = EchoAuth.bearer(() => 't', endpoint: url(), client: given);
      expect(
        await auth.authorize('1.2', 'private-a'),
        containsPair('auth', 'key:sig'),
      );
      expect(given.sent, 1);
      final server = await FakePusher.start();
      addTearDown(server.close);
      final echo = Echo.reverb(key: 'k', host: server.host, auth: auth);
      await echo.disconnect();
      expect(given.closed, isFalse);

      // Without a client: one is made, and after disconnect made again.
      final own = EchoAuth.endpoint(url());
      final second = Echo.reverb(key: 'k', host: server.host, auth: own);
      expect(
        await own.authorize('1.2', 'private-a'),
        containsPair('auth', 'key:sig'),
      );
      await second.disconnect();
      expect(
        await own.authorize('1.2', 'private-a'),
        containsPair('auth', 'key:sig'),
      );
    });
  });

  group('an authorizer of the application', () {
    test('checked the same way, with status 0', () async {
      for (final (result, message) in <(Map<String, Object?>, String)>[
        ({}, 'no auth'),
        ({'auth': 1}, 'no auth'),
        (
          {
            'auth': 'k:s',
            'shared_secret': base64.encode([1, 2, 3]),
          },
          'shared_secret is 3 bytes, not 32',
        ),
      ]) {
        final auth = EchoAuth.custom((_, _) => result);
        await expectLater(
          auth.authorize('1.2', 'private-encrypted-orders'),
          throwsA(refused(0, message)),
          reason: message,
        );
      }
    });

    test('an encrypted channel with a short key is not subscribed: the '
        'error says why', () async {
      final server = await FakePusher.start();
      addTearDown(server.close);
      final echo = Echo.reverb(
        key: 'k',
        host: server.host,
        auth: EchoAuth.custom(
          (_, _) => {
            'auth': 'k:s',
            'shared_secret': base64.encode(List.filled(16, 1)),
          },
        ),
      );
      addTearDown(echo.disconnect);
      final errors = <Object>[];
      final reported = <Map<String, Object?>>[];
      echo.onError.listen(reported.add);
      echo.encryptedPrivate('orders').error(errors.add);
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (errors.isEmpty && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(errors.single, refused(0, 'shared_secret is 16 bytes, not 32'));
      expect(reported.single, {
        'channel': 'private-encrypted-orders',
        'status': 0,
      });
      expect(
        server.received.where((f) => f['event'] == 'pusher:subscribe'),
        isEmpty,
      );
    });
  });

  test('Poly1305 with a key that is not 32 bytes: an ArgumentError', () {
    expect(() => Secretbox.poly1305([1, 2], [1, 2, 3]), throwsArgumentError);
  });
}

/// A client that counts what it sends and whether it was closed.
final class _CountingClient extends http.BaseClient {
  final _inner = http.Client();
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
