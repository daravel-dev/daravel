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

  Future<void> start(String upstream) async {
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'LOG_LEVEL': 'emergency',
        })
        .withRouting(
          api: (router) => router.get('/orders', (_) => {'from': 'daravel'}),
        )
        .withUpstream(url: upstream)
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
