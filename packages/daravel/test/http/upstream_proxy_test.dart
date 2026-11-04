import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// What the "Laravel" upstream received.
final class _Seen {
  _Seen(this.method, this.uri, this.headers, this.body);
  final String method;
  final Uri uri;
  final HttpHeaders headers;
  final List<int> body;
}

/// A stand-in for the legacy application: echoes what it got and answers a
/// few special paths.
Future<(HttpServer, List<_Seen>)> legacyServer() async {
  final seen = <_Seen>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
    ..autoCompress = false;
  server.listen((request) async {
    final body = await request.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    seen.add(_Seen(request.method, request.uri, request.headers, body));
    final response = request.response;
    switch (request.uri.path) {
      case '/legacy/redirect':
        response
          ..statusCode = 302
          ..headers.set('location', '/login');
      case '/legacy/gzip':
        response.headers
          ..set('content-encoding', 'gzip')
          ..contentType = ContentType.text;
        response.add(gzip.encode(utf8.encode('compressed by Laravel')));
      case '/legacy/teapot':
        response.statusCode = 418;
      default:
        response
          ..headers.contentType = ContentType.json
          ..headers.add('set-cookie', 'XSRF-TOKEN=a; Path=/')
          ..headers.add('set-cookie', 'laravel_session=b; Path=/; HttpOnly')
          ..headers.set('x-powered-by', 'PHP/8.3')
          ..write(
            jsonEncode({
              'from': 'laravel',
              'method': request.method,
              'bytes': body.length,
            }),
          );
    }
    await response.close();
  });
  return (server, seen);
}

void main() {
  late HttpServer legacy;
  late List<_Seen> seen;
  late Application app;
  late ServerEngine engine;
  late HttpClient client;
  late Uri base;

  Future<void> start(String upstream, {bool preserveHost = false}) async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'LOG_LEVEL': 'emergency',
        })
        .withRouting(
          api: (router) => router
            ..get('/orders', (_) => {'from': 'daravel'})
            ..put(
              '/orders/{id}',
              (Request request) async => {
                'from': 'daravel',
                'method': request.method,
                'name': (await request.all())['name'],
              },
            ),
        )
        .withUpstream(url: upstream, preserveHost: preserveHost)
        .create();
    await app.boot();
    engine = ServerEngine(
      app,
      const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
      kernel: app.kernel,
      logger: Logger(minimumLevel: LogLevel.emergency),
    );
    await engine.start();
    base = Uri.parse('http://127.0.0.1:${engine.port}');
  }

  setUp(() async {
    (legacy, seen) = await legacyServer();
    client = HttpClient()..autoUncompress = false;
    await start('http://127.0.0.1:${legacy.port}');
  });

  tearDown(() async {
    client.close(force: true);
    await engine.stop();
    await legacy.close(force: true);
    Container.setRoot(null);
  });

  Future<(HttpClientResponse, List<int>)> send(
    String method,
    String path, {
    Map<String, String> headers = const {},
    List<int>? body,
  }) async {
    final request = await client.openUrl(method, base.resolve(path))
      ..followRedirects = false;
    headers.forEach(request.headers.set);
    if (body != null) {
      request.contentLength = body.length;
      request.add(body);
    }
    final response = await request.close();
    final bytes = await response.fold<List<int>>(
      <int>[],
      (all, chunk) => all..addAll(chunk),
    );
    return (response, bytes);
  }

  test(
    'a migrated route answers from Daravel; Laravel never sees it',
    () async {
      final (response, body) = await send('GET', '/api/orders');
      expect(response.statusCode, 200);
      expect(jsonDecode(utf8.decode(body)), {'from': 'daravel'});
      expect(seen, isEmpty);
    },
  );

  test(
    'the rest goes to Laravel with its query, headers and cookies',
    () async {
      final (response, body) = await send(
        'GET',
        '/legacy/reports?year=2026&q=a%20b',
        headers: {
          'authorization': 'Bearer 1|token',
          'cookie': 'laravel_session=old',
          'x-forwarded-for': '203.0.113.9',
        },
      );
      expect(response.statusCode, 200);
      expect(jsonDecode(utf8.decode(body)), containsPair('from', 'laravel'));
      expect(response.headers['set-cookie'], [
        'XSRF-TOKEN=a; Path=/',
        'laravel_session=b; Path=/; HttpOnly',
      ]);
      expect(
        response.headers.value('x-powered-by'),
        isNull,
        reason: 'stripped',
      );

      final got = seen.single;
      expect(got.uri.path, '/legacy/reports');
      expect(got.uri.queryParameters, {'year': '2026', 'q': 'a b'});
      expect(got.headers.value('authorization'), 'Bearer 1|token');
      expect(got.headers.value('cookie'), 'laravel_session=old');
      expect(got.headers.value('x-forwarded-for'), '203.0.113.9, 127.0.0.1');
      expect(got.headers.value('x-forwarded-proto'), 'http');
      expect(got.headers.value('x-forwarded-port'), '${engine.port}');
      expect(got.headers.host, '127.0.0.1');
      expect(got.headers.port, legacy.port, reason: 'the upstream host');
    },
  );

  test('a method Daravel lacks on a migrated path goes to Laravel, body '
      'intact', () async {
    // Daravel has GET /api/orders; POST is still Laravel's (not a 405).
    final payload = List<int>.generate(3 * 1024 * 1024, (i) => i % 251);
    final (response, body) = await send(
      'POST',
      '/api/orders',
      headers: {'content-type': 'application/octet-stream'},
      body: payload,
    );
    expect(response.statusCode, 200);
    expect(jsonDecode(utf8.decode(body)), {
      'from': 'laravel',
      'method': 'POST',
      'bytes': payload.length,
    });
    expect(seen.single.body, payload);
  });

  test('a _method override reaches Laravel as the POST the client sent, '
      'body intact', () async {
    // PHP parses a multipart body only for a POST: forwarding the PUT that
    // Daravel's override reads would leave Laravel's input and files empty.
    const boundary = 'daravel-boundary';
    final multipart = utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="_method"\r\n\r\n'
      'PUT\r\n'
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="avatar"; filename="a.bin"\r\n'
      'Content-Type: application/octet-stream\r\n\r\n'
      '${'x' * 4096}\r\n'
      '--$boundary--\r\n',
    );
    final (response, body) = await send(
      'POST',
      '/legacy/profile',
      headers: {'content-type': 'multipart/form-data; boundary=$boundary'},
      body: multipart,
    );
    expect(response.statusCode, 200);
    expect(jsonDecode(utf8.decode(body)), containsPair('method', 'POST'));
    expect(seen.single.method, 'POST');
    expect(seen.single.body, multipart);

    final form = utf8.encode('_method=DELETE&id=7');
    await send(
      'POST',
      '/legacy/items',
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: form,
    );
    expect(seen.last.method, 'POST');
    expect(seen.last.body, form);

    await send(
      'POST',
      '/legacy/items',
      headers: {'x-http-method-override': 'PATCH'},
    );
    expect(seen.last.method, 'POST');
    expect(seen.last.headers.value('x-http-method-override'), 'PATCH');

    // A plain upload, no override: the bytes still arrive.
    final upload = utf8.encode(
      '--$boundary\r\n'
      'Content-Disposition: form-data; name="file"; filename="b.bin"\r\n'
      'Content-Type: application/octet-stream\r\n\r\n'
      '${'y' * 8192}\r\n'
      '--$boundary--\r\n',
    );
    await send(
      'POST',
      '/legacy/uploads',
      headers: {'content-type': 'multipart/form-data; boundary=$boundary'},
      body: upload,
    );
    expect(seen.last.method, 'POST');
    expect(seen.last.body, upload);

    final json = utf8.encode('{"name":"kept"}');
    await send(
      'PUT',
      '/legacy/items/7',
      headers: {'content-type': 'application/json'},
      body: json,
    );
    expect(seen.last.method, 'PUT');
    expect(seen.last.body, json);
  });

  test('beside the proxy, a migrated route still takes the override', () async {
    final (response, body) = await send(
      'POST',
      '/api/orders/7',
      headers: {'content-type': 'application/x-www-form-urlencoded'},
      body: utf8.encode('_method=PUT&name=local'),
    );
    expect(response.statusCode, 200);
    expect(jsonDecode(utf8.decode(body)), {
      'from': 'daravel',
      'method': 'PUT',
      'name': 'local',
    });
    expect(seen, isEmpty);
  });

  test('preserveHost sends the Host the client sent, port or none', () async {
    await engine.stop();
    Container.setRoot(null);
    await start('http://127.0.0.1:${legacy.port}', preserveHost: true);

    for (final host in ['example.test', 'example.test:8443']) {
      await send('GET', '/legacy/page', headers: {'host': host});
      expect(
        seen.last.headers.value('host'),
        host,
        reason: "not the upstream's port appended",
      );
      expect(seen.last.headers.value('x-forwarded-host'), host.split(':')[0]);
    }
  });

  test('redirects, statuses and compressed bodies pass through', () async {
    final (redirect, _) = await send('GET', '/legacy/redirect');
    expect(redirect.statusCode, 302);
    expect(redirect.headers.value('location'), '/login');

    final (teapot, _) = await send('DELETE', '/legacy/teapot');
    expect(teapot.statusCode, 418);
    expect(seen.last.method, 'DELETE');

    final (gzipped, bytes) = await send(
      'GET',
      '/legacy/gzip',
      headers: {'accept-encoding': 'gzip'},
    );
    expect(gzipped.headers.value('content-encoding'), 'gzip');
    expect(utf8.decode(gzip.decode(bytes)), 'compressed by Laravel');
  });

  test('Laravel down answers 502', () async {
    await legacy.close(force: true);
    final (response, body) = await send('GET', '/legacy/anything');
    expect(response.statusCode, 502);
    expect(jsonDecode(utf8.decode(body)), {'message': 'Bad Gateway'});
  });

  test("the upstream's path prefixes the request's", () {
    final proxy = UpstreamProxy(Uri.parse('http://legacy.internal/app/'));
    addTearDown(proxy.close);
    final request = Request.fake(path: '/users/7?tab=orders');
    expect(
      '${proxy.target(request)}',
      'http://legacy.internal/app/users/7?tab=orders',
    );
    expect(() => UpstreamProxy(Uri.parse('/relative')), throwsArgumentError);
  });

  test(
    'withUpstream() without a URL or UPSTREAM_URL refuses to boot',
    () async {
      final broken = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withUpstream()
          .create();
      await expectLater(broken.boot(), throwsA(isA<ConfigException>()));
    },
  );
}
