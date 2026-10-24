import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class _Tag implements TerminableMiddleware {
  const _Tag(this.label, this.log);
  final String label;
  final List<String> log;

  @override
  Future<Response> handle(Request request, Next next) async {
    log.add('handle:$label');
    return next(request);
  }

  @override
  Future<void> terminate(Request request, Response response) async {
    log.add('terminate:$label:${response.status}');
  }
}

final class _Slow implements Middleware {
  const _Slow();
  @override
  Future<Response> handle(Request request, Next next) => next(request);
}

Future<Response> _run(Middleware m, Request request, [Object? result]) =>
    m.handle(request, (req) async => HttpKernel.toResponse(result, req));

void main() {
  group('Cidr', () {
    test('matches IPv4 and IPv6 networks and single addresses', () {
      expect(Cidr.parse('10.0.0.0/8').contains('10.42.1.9'), isTrue);
      expect(Cidr.parse('10.0.0.0/8').contains('11.0.0.1'), isFalse);
      expect(Cidr.parse('192.168.1.10').contains('192.168.1.10'), isTrue);
      expect(Cidr.parse('192.168.1.10').contains('192.168.1.11'), isFalse);
      expect(Cidr.parse('172.16.0.0/12').contains('172.31.255.255'), isTrue);
      expect(Cidr.parse('172.16.0.0/12').contains('172.32.0.0'), isFalse);
      expect(Cidr.parse('::1/128').contains('::1'), isTrue);
      expect(Cidr.parse('2001:db8::/32').contains('2001:db8:1::5'), isTrue);
      expect(Cidr.parse('10.0.0.0/8').contains('::1'), isFalse);
      expect(() => Cidr.parse('nope'), throwsFormatException);
      expect(() => Cidr.parse('10.0.0.0/33'), throwsFormatException);
    });
  });

  group('TrustProxiesMiddleware', () {
    final headers = <String, String>{
      'x-forwarded-for': '203.0.113.9, 10.0.0.5, 10.0.0.2',
      'x-forwarded-proto': 'https',
      'x-forwarded-host': 'app.example.test',
    };

    test('ignores forwarded headers from untrusted peers', () async {
      final request = Request.fake(headers: headers, ip: '198.51.100.7');
      await _run(
        TrustProxiesMiddleware(proxies: const ['10.0.0.0/8']),
        request,
      );
      expect(request.ip, '198.51.100.7');
      expect(request.ips, ['198.51.100.7']);
      expect(request.scheme, 'http');
      expect(request.isSecure, isFalse);
    });

    test('walks X-Forwarded-For from the right past trusted proxies', () async {
      final request = Request.fake(headers: headers, ip: '10.0.0.1');
      await _run(
        TrustProxiesMiddleware(proxies: const ['10.0.0.0/8']),
        request,
      );
      expect(request.ip, '203.0.113.9');
      expect(request.ips, ['203.0.113.9', '10.0.0.5', '10.0.0.2', '10.0.0.1']);
      expect(request.scheme, 'https');
      expect(request.isSecure, isTrue);
      expect(request.host, 'app.example.test');
    });

    test('a spoofed trusted address in the chain is not the client', () async {
      final request = Request.fake(
        headers: {'x-forwarded-for': '10.0.0.99, 203.0.113.9'},
        ip: '10.0.0.1',
      );
      await _run(
        TrustProxiesMiddleware(proxies: const ['10.0.0.0/8']),
        request,
      );
      expect(request.ip, '203.0.113.9');
    });

    test('trustAll and header selection', () async {
      final request = Request.fake(headers: headers, ip: '8.8.8.8');
      await _run(
        TrustProxiesMiddleware(
          trustAll: true,
          headers: const {ForwardedHeader.forwardedFor},
        ),
        request,
      );
      expect(request.ip, '203.0.113.9');
      expect(request.scheme, 'http');
      expect(request.host, 'localhost');
    });
  });

  group('BodyLimitsMiddleware', () {
    test('rejects declared oversize bodies with 413 before reading', () async {
      final request = Request.fake(
        method: 'POST',
        body: 'x' * 10,
        headers: {'content-type': 'application/json', 'content-length': '5000'},
      );
      final response = await _run(
        const BodyLimitsMiddleware(json: 1024),
        request,
      );
      expect(response.status, 413);
    });

    test('enforces the limit when the body is read', () async {
      final request = Request.fake(
        method: 'POST',
        body: 'x' * 2048,
        headers: {'content-type': 'text/plain'},
      );
      request.headers.remove('content-length');
      await _run(const BodyLimitsMiddleware(other: 1024), request);
      await expectLater(
        request.bytes(),
        throwsA(isA<PayloadTooLargeHttpException>()),
      );
    });

    test('limits JSON nesting depth', () async {
      final deep =
          List.generate(5, (_) => '[').join() +
          List.generate(5, (_) => ']').join();
      final request = Request.fake(
        method: 'POST',
        body: deep,
        headers: {'content-type': 'application/json'},
      );
      await _run(const BodyLimitsMiddleware(jsonDepth: 3), request);
      await expectLater(
        request.body(),
        throwsA(isA<BadRequestHttpException>()),
      );
    });

    test('route body limits override the defaults', () async {
      final router = Router()
        ..post('/upload', (_) => null).bodyLimit(10)
        ..compile(MiddlewareRegistry());
      final request = Request.fake(
        method: 'POST',
        body: 'x' * 20,
        headers: {'content-type': 'text/plain'},
      );
      request.bindRoute(router.lookup('POST', '/upload')!.value, const {});
      expect(const BodyLimitsMiddleware().limitFor(request), 10);
    });
  });

  group('CorsMiddleware', () {
    test('passes through requests without Origin', () async {
      final response = await _run(
        CorsMiddleware(const CorsConfig(allowedOrigins: ['*'])),
        Request.fake(),
        'ok',
      );
      expect(response.headers.has('access-control-allow-origin'), isFalse);
    });

    test(
      'answers preflight for allowed origins without hitting the route',
      () async {
        var reached = false;
        final cors = CorsMiddleware(
          const CorsConfig(
            allowedOrigins: ['https://*.example.test'],
            supportsCredentials: true,
            exposedHeaders: ['x-request-id'],
          ),
        );
        final response = await cors.handle(
          Request.fake(
            method: 'OPTIONS',
            path: '/api/users',
            headers: {
              'origin': 'https://app.example.test',
              'access-control-request-method': 'PUT',
              'access-control-request-headers': 'content-type, authorization',
            },
          ),
          (req) async {
            reached = true;
            return Response.text('route');
          },
        );
        expect(reached, isFalse);
        expect(response.status, 204);
        expect(
          response.headers['access-control-allow-origin'],
          'https://app.example.test',
        );
        expect(response.headers['access-control-allow-credentials'], 'true');
        expect(response.headers['access-control-allow-methods'], 'PUT');
        expect(
          response.headers['access-control-allow-headers'],
          'content-type, authorization',
        );
        expect(response.headers['access-control-max-age'], '3600');
        expect(response.headers['vary'], 'Origin');
      },
    );

    test('decorates simple responses and exposes headers', () async {
      final cors = CorsMiddleware(
        const CorsConfig(
          allowedOrigins: ['*'],
          exposedHeaders: ['x-request-id'],
        ),
      );
      final response = await _run(
        cors,
        Request.fake(headers: {'origin': 'https://any.test'}),
        'ok',
      );
      expect(response.headers['access-control-allow-origin'], '*');
      expect(response.headers['access-control-expose-headers'], 'x-request-id');
    });

    test('denies unknown origins without CORS headers', () async {
      final cors = CorsMiddleware(
        const CorsConfig(allowedOrigins: ['https://ok.test']),
      );
      final response = await _run(
        cors,
        Request.fake(headers: {'origin': 'https://evil.test'}),
        'ok',
      );
      expect(response.status, 200);
      expect(response.headers.has('access-control-allow-origin'), isFalse);
      expect(response.headers['vary'], 'Origin');
    });

    test('refuses wildcard origins with credentials', () {
      expect(
        () => CorsMiddleware(
          const CorsConfig(allowedOrigins: ['*'], supportsCredentials: true),
        ),
        throwsArgumentError,
      );
    });
  });

  group('SecurityHeadersMiddleware', () {
    test('adds conservative headers and respects existing ones', () async {
      final request = Request.fake(headers: {'authorization': 'Bearer x'});
      request.applyForwarded(scheme: 'https');
      final response = await _run(
        const SecurityHeadersMiddleware(),
        request,
        Response.html('<p>hi</p>').withHeader('referrer-policy', 'no-referrer'),
      );
      expect(response.headers['x-content-type-options'], 'nosniff');
      expect(response.headers['x-frame-options'], 'DENY');
      expect(response.headers['referrer-policy'], 'no-referrer');
      expect(
        response.headers['strict-transport-security'],
        startsWith('max-age=31536000'),
      );
      expect(response.headers['cache-control'], 'no-store');

      final json = await _run(
        const SecurityHeadersMiddleware(),
        Request.fake(),
        {'a': 1},
      );
      expect(json.headers.has('x-frame-options'), isFalse);
      expect(json.headers.has('strict-transport-security'), isFalse);
    });
  });

  group('input normalization', () {
    test(
      'trims strings except passwords and converts empty strings to null',
      () async {
        final request = Request.fake(
          method: 'POST',
          json: {
            'name': '  Ana ',
            'password': '  secret ',
            'bio': '',
            'tags': [' a ', ''],
            'meta': {'city': ' Denpasar '},
          },
        );
        await _run(const TrimStringsMiddleware(), request);
        await _run(const ConvertEmptyStringsToNullMiddleware(), request);
        final input = await request.all();
        expect(input['name'], 'Ana');
        expect(input['password'], '  secret ');
        expect(input['bio'], isNull);
        expect(input['tags'], ['a', null]);
        expect((input['meta']! as Map<String, Object?>)['city'], 'Denpasar');
        expect(await request.input<String>('meta.city'), 'Denpasar');
      },
    );
  });

  group('MiddlewareRegistry', () {
    test('resolves aliases with parameters, groups and priority', () {
      final log = <String>[];
      final registry = MiddlewareRegistry()
        ..aliasFactory('tag', (params) => _Tag(params.join('+'), log))
        ..alias('slow', const _Slow())
        ..group('web', ['tag:a,b', 'slow'])
        ..priority([_Slow]);
      final resolved = registry.resolveAll(['web', 'tag:c']);
      expect(resolved.map((m) => m.runtimeType), [_Slow, _Tag, _Tag]);
      expect((resolved[1] as _Tag).label, 'a+b');
      expect((resolved[2] as _Tag).label, 'c');
      expect(() => registry.resolve('nope'), throwsStateError);
    });
  });

  group('kernel integration', () {
    late List<String> log;
    late Application app;

    setUp(() async {
      log = <String>[];
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withRouting(
            api: (r) {
              r
                  .get('/fast', (req) {
                    req.defer(() => log.add('deferred'));
                    return 'ok';
                  })
                  .middleware([_Tag('route', log)]);
              r
                  .get('/slow', (_) async {
                    await Future<void>.delayed(
                      const Duration(milliseconds: 200),
                    );
                    return 'late';
                  })
                  .timeout(const Duration(milliseconds: 20));
              r
                  .get('/slower', (_) async {
                    await Future<void>.delayed(const Duration(seconds: 6));
                    return 'late';
                  })
                  .timeout(const Duration(seconds: 2));
              r
                  .get('/quick', (_) => 'fine')
                  .timeout(const Duration(seconds: 2));
              r.post('/echo', (req) async => await req.all());
            },
          )
          .withMiddleware((m) {
            m.use([
              _Tag('global', log),
              const TrimStringsMiddleware(),
              const BodyLimitsMiddleware(json: 64),
            ]);
          })
          .create();
      await app.boot();
    });

    tearDown(() => app.shutdown());

    test('terminate runs after the response for global and route middleware, then deferred callbacks', () async {
      final request = Request.fake(path: '/api/fast');
      final response = await app.handle(request);
      expect(response.status, 200);
      expect(log, ['handle:global', 'handle:route']);
      await app.kernel.terminate(request, response);
      expect(log, [
        'handle:global',
        'handle:route',
        'terminate:global:200',
        'terminate:route:200',
        'deferred',
      ]);
    });

    test('route timeouts answer 503', () async {
      final response = await app.handle(Request.fake(path: '/api/slow'));
      expect(response.status, 503);
      expect(
        (jsonDecode(await response.bodyText())
            as Map<String, Object?>)['message'],
        contains('did not complete'),
      );
    });

    test('long timeouts fire within a second of the deadline', () async {
      final watch = Stopwatch()..start();
      expect((await app.handle(Request.fake(path: '/api/quick'))).status, 200);
      final response = await app.handle(Request.fake(path: '/api/slower'));
      expect(response.status, 503);
      expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 2)));
      // Within the sweep interval, with room for a busy CI machine.
      expect(watch.elapsed, lessThan(const Duration(seconds: 6)));
    });

    test(
      'oversize JSON bodies answer 413 and trimmed input reaches handlers',
      () async {
        final big = await app.handle(
          Request.fake(
            method: 'POST',
            path: '/api/echo',
            json: {'x': 'y' * 100},
          ),
        );
        expect(big.status, 413);
        final ok = await app.handle(
          Request.fake(
            method: 'POST',
            path: '/api/echo',
            json: {'name': ' Bo '},
          ),
        );
        expect(jsonDecode(await ok.bodyText()), {'name': 'Bo'});
      },
    );
  });
}
