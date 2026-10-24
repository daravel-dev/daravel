import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  late Application app;

  setUp(() async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .create();
    await app.boot();
  });
  tearDown(() => app.shutdown());

  group('fake', () {
    test('stubs by pattern, records requests and asserts', () async {
      await app.run(() async {
        final http = Http.fake({
          'api.stripe.com/v1/*': Http.response({'id': 'ch_1'}, 201),
          'example.org/*': (ClientRequest r) =>
              Http.response('echo ${r.method}'),
        });
        final charge = await Http.withToken('sk_test')
            .post('https://api.stripe.com/v1/charges', json: {'amount': 5000});
        expect(charge.status, 201);
        expect(charge.json('id'), 'ch_1');
        expect(charge.successful, isTrue);
        expect((await Http.delete('http://example.org/x')).body, 'echo DELETE');
        expect((await Http.get('https://other.test/')).status, 200);

        http
          ..assertSentCount(3)
          ..assertSent(
            (r) =>
                r.url.host == 'api.stripe.com' &&
                r.json('amount') == 5000 &&
                r.header('authorization') == 'Bearer sk_test' &&
                r.isJson,
          )
          ..assertNotSent((r) => r.method == 'PUT');
        expect(() => http.assertNothingSent(), throwsStateError);
      });
    });

    test('sequences, retries and failed responses', () async {
      await app.run(() async {
        final http = Http.fake({
          'flaky.test/*': Http.sequence([
            Http.response({'error': 'busy'}, 503),
            Http.response({'error': 'busy'}, 503),
            Http.response({'ok': true}),
          ]),
        });
        final response = await Http.retry(
          3,
          delay: Duration.zero,
        ).get('https://flaky.test/status');
        expect(response.ok, isTrue);
        expect(response.json('ok'), isTrue);
        http.assertSentCount(3);

        final failed = Http.response({'message': 'nope'}, 422);
        expect(failed.clientError, isTrue);
        expect(failed.json('message'), 'nope');
        expect(
          failed.throwIfFailed,
          throwsA(
            isA<RequestException>().having(
              (e) => e.response.status,
              'status',
              422,
            ),
          ),
        );
        expect(failed.throwIfServerError(), same(failed));
      });
    });

    test('preventStrayRequests throws for unstubbed URLs', () async {
      await app.run(() async {
        Http.fake({'known.test/*': Http.response('ok')});
        Http.preventStrayRequests();
        expect((await Http.get('https://known.test/a')).body, 'ok');
        await expectLater(
          Http.get('https://elsewhere.example/'),
          throwsA(isA<StrayRequestException>()),
        );
      });
    });
  });

  group('network', () {
    late HttpServer server;
    final received = <Map<String, Object?>>[];

    setUp(() async {
      received.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final body = await utf8.decoder.bind(request).join();
        received.add({
          'method': request.method,
          'path': request.uri.path,
          'query': request.uri.queryParametersAll,
          'auth': request.headers.value('authorization'),
          'type': request.headers.contentType?.mimeType,
          'body': body,
        });
        if (request.uri.path == '/slow') {
          await Future<void>.delayed(const Duration(seconds: 2));
        }
        request.response
          ..statusCode = request.uri.path == '/missing' ? 404 : 200
          ..headers.contentType = ContentType.json
          ..headers.set('x-trace', 'abc')
          ..write(jsonEncode({'echo': body}));
        await request.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    test('sends headers, query and bodies; reads the response', () async {
      await app.run(() async {
        final base = 'http://127.0.0.1:${server.port}';
        final json = await Http.baseUrl(base)
            .withBasicAuth('ana', 'secret')
            .post('/orders', json: {'qty': 2});
        expect(json.status, 200);
        expect(json.header('x-trace'), 'abc');
        expect(json.json('echo'), '{"qty":2}');

        final form = await Http.baseUrl(base)
            .asForm()
            .post('orders', json: {'qty': 3});
        expect(form.json('echo'), 'qty=3');

        final query = await Http.get(
          '$base/search',
          query: {
            'q': 'dart',
            'tags': ['a', 'b'],
          },
        );
        expect(query.successful, isTrue);
        final missing = await Http.get('$base/missing');
        expect(missing.status, 404);
        expect(missing.failed, isTrue);

        expect(
          received[0]['auth'],
          'Basic ${base64.encode(utf8.encode('ana:secret'))}',
        );
        expect(received[0]['type'], 'application/json');
        expect(received[1]['type'], 'application/x-www-form-urlencoded');
        expect(received[2]['query'], {
          'q': ['dart'],
          'tags': ['a', 'b'],
        });
      });
    });

    test('timeouts and unreachable hosts are ConnectionException', () async {
      await app.run(() async {
        await expectLater(
          Http.timeout(const Duration(milliseconds: 200))
              .get('http://127.0.0.1:${server.port}/slow'),
          throwsA(isA<ConnectionException>()),
        );
        final closed = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = closed.port;
        await closed.close();
        await expectLater(
          Http.retry(2, delay: Duration.zero).get('http://127.0.0.1:$port/'),
          throwsA(isA<ConnectionException>()),
        );
      });
    });
  });
}
