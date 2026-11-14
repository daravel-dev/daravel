import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// HC-1 (Reviewer RSEQ 50/53): outgoing HTTP errors show URLs with the
/// password and sensitive query values masked, a sub-second timeout reads
/// in milliseconds, the retry helpers do not send a timed-out POST again,
/// and a failed broadcast does not quote the whole response body.
void main() {
  const secrets = ['PASS', 'TOKENVALUE', 'KEYVALUE'];
  const query = 'token=TOKENVALUE&api_key=KEYVALUE&page=2';

  void expectRedacted(String text) {
    for (final secret in secrets) {
      expect(text, isNot(contains(secret)), reason: text);
    }
    expect(text, contains('page=2'), reason: text);
  }

  test('redactUrl masks the password and sensitive query values only', () {
    final masked = redactUrl('http://user:PASS@host/p?$query#frag');
    expect(masked, 'http://user:***@host/p?token=***&api_key=***&page=2#frag');
    expect(
      redactUrl('https://h/x?Auth_Signature=abc&X-Amz-Signature=def&q=1'),
      'https://h/x?Auth_Signature=***&X-Amz-Signature=***&q=1',
    );
    expect(redactUrl('https://h/x?page=1'), 'https://h/x?page=1');
  });

  test('a connection that fails shows the URL redacted', () async {
    // Nothing listens on port 1: refused at once.
    Object? error;
    try {
      await HttpClientFactory().request().get(
        'http://user:PASS@127.0.0.1:1/p?$query',
      );
    } on ConnectionException catch (e) {
      error = e;
    }
    expect(error, isA<ConnectionException>());
    expectRedacted('$error');
  });

  test(
    'with APP_DEBUG, the error body and the log show the URL redacted',
    () async {
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({
            'APP_ENV': 'testing',
            'APP_DEBUG': 'true',
            'DB_DATABASE': ':memory:',
          })
          .withLogLevel(LogLevel.debug)
          .withRouting(
            web: (router) => router.get('/call', (Request request) async {
              await Http.get('http://user:PASS@127.0.0.1:1/p?$query');
              return 'unreachable';
            }),
          )
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      final logs = await app.run(() async => Log.spy());
      final response = await TestClient(app).get('/call');
      expect(response.status, 500);
      expect(response.body, contains('Could not reach'));
      expectRedacted(response.body);
      final logged = logs.records
          .map((r) => '${r.message} ${r.context} ${r.error ?? ''}')
          .join('\n');
      expect(logged, contains('Could not reach'));
      expectRedacted(logged);
    },
  );

  test('a stray request shows the URL redacted', () async {
    final factory = HttpClientFactory()
      ..fake(const {})
      ..preventStrayRequests(true);
    Object? error;
    try {
      await factory.request().get('http://user:PASS@stray.test/p?$query');
    } on StrayRequestException catch (e) {
      error = e;
    }
    expect(error, isA<StrayRequestException>());
    expectRedacted('$error');
  });

  group('against a server that never answers', () {
    late ServerSocket server;
    var received = 0;

    setUp(() async {
      received = 0;
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      // Reads the request and keeps the connection open without a reply.
      server.listen((socket) {
        received++;
        socket.listen((_) {});
      });
    });
    tearDown(() => server.close());

    String url() => 'http://127.0.0.1:${server.port}/p?$query';

    test('a sub-second timeout reads in milliseconds', () async {
      Object? error;
      try {
        await HttpClientFactory()
            .request()
            .timeout(const Duration(milliseconds: 300))
            .get(url());
      } on ConnectionException catch (e) {
        error = e;
      }
      expect('$error', contains('300ms'));
      expectRedacted('$error');
    });

    test('the retry helpers send a timed-out POST once, a GET again', () async {
      for (final when in [
        Http.retryOnConnectionOr5xx,
        Http.retryOnConnectionOnly,
      ]) {
        received = 0;
        await expectLater(
          HttpClientFactory()
              .request()
              .timeout(const Duration(milliseconds: 200))
              .retry(3, delay: Duration.zero, when: when)
              .post(url(), body: 'charge'),
          throwsA(isA<ConnectionException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(received, 1, reason: 'POST');
        received = 0;
        await expectLater(
          HttpClientFactory()
              .request()
              .timeout(const Duration(milliseconds: 200))
              .retry(3, delay: Duration.zero, when: when)
              .get(url()),
          throwsA(isA<ConnectionException>()),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(received, 3, reason: 'GET');
      }
    });
  });

  test('isIdempotent follows RFC 9110', () {
    for (final method in ['GET', 'head', 'OPTIONS', 'TRACE', 'PUT', 'DELETE']) {
      expect(Http.isIdempotent(method), isTrue, reason: method);
    }
    for (final method in ['POST', 'PATCH', 'CONNECT', null]) {
      expect(Http.isIdempotent(method), isFalse, reason: '$method');
    }
  });

  test(
    'a failed broadcast quotes at most 120 characters of the body',
    () async {
      final factory = HttpClientFactory();
      final body = 'x' * 500;
      // The URL carries the port (reverb.test:8080): match it whole.
      factory.fake({'*reverb.test*': Http.response(body, 500)});
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
      Object? error;
      try {
        await manager.send('E', ['c'], {'id': 1});
      } on StateError catch (e) {
        error = e;
      }
      expect('$error', contains('x' * 120));
      expect('$error', isNot(contains('x' * 121)));
      expect('$error', contains('(truncated...)'));
    },
  );
}
