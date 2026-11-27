import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `BodyLimitsMiddleware` used to replace the limit a request arrived with
/// (`HTTP_MAX_BODY`) by its content-type limit, so a small `HTTP_MAX_BODY`
/// was raised to 1 MiB for JSON and forms and 50 MiB for the rest. As
/// global middleware it also refused a declared `Content-Length` before the
/// route was known, so a route's larger `.bodyLimit(n)` never applied.
///
/// Now the middleware's limits replace the engine's JSON and form limits
/// (`HTTP_MAX_JSON_BODY`, `HTTP_MAX_FORM_BODY`) but never exceed the limit
/// the request arrived with, and a route's `.bodyLimit(n)` decides for its
/// route.
///
/// Adapted from the test of the same name on the 1.x line (1.27.8). A test
/// that differs from it says why in a comment starting with "main:".
const _refusal = '{\n    "message": "The POST data is too large."\n}';

const _kib64 = 64 << 10;
const _mib = 1 << 20;

final class _Tag implements Middleware {
  const _Tag(this.label, this.log);
  final String label;
  final List<String> log;

  @override
  Future<Response> handle(Request request, Next next) {
    log.add(label);
    return next(request);
  }
}

/// Reads the body before the middleware after it sees the request.
final class _ReadBody implements Middleware {
  const _ReadBody();

  @override
  Future<Response> handle(Request request, Next next) async {
    await request.bytes();
    return next(request);
  }
}

Future<Map<String, Object?>> _length(Request request) async =>
    <String, Object?>{'length': (await request.bytes()).length};

void _routes(Router router, List<String> log) {
  router.post('/echo', _length);
  router.post('/wide', _length).bodyLimit(4 * _mib);
  router.get('/only-get', (_) => 'got');
  router
      .post('/guarded', (_) {
        log.add('handler');
        return 'ok';
      })
      .middleware([_Tag('route', log)]);
  router.post('/ignore', (_) => 'ignored');
}

Future<Application> _app({
  List<Middleware> global = const <Middleware>[BodyLimitsMiddleware()],
  void Function(Router router)? routes,
  List<String>? log,
}) async {
  final app = Application.configure(basePath: Directory.systemTemp.path)
      .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
      .withLogLevel(LogLevel.critical)
      .withRouting(
        apiPrefix: '',
        api: routes ?? (router) => _routes(router, log ?? <String>[]),
      )
      .withMiddleware((m) => m.use(global))
      .create();
  await app.boot();
  addTearDown(app.shutdown);
  return app;
}

/// A POST of [size] bytes. [arrived] is the limit the request starts with
/// (what the engine sets from `HTTP_MAX_BODY`); [declare] false removes the
/// `Content-Length`, as a chunked body has none.
Request _post(
  String path,
  int size, {
  String type = 'application/json',
  int? arrived = Request.defaultMaxBodyBytes,
  bool declare = true,
  String method = 'POST',
}) {
  final request = Request.fake(
    method: method,
    path: path,
    body: 'x' * size,
    headers: {'content-type': type},
  );
  if (!declare) {
    request.headers.remove('content-length');
  }
  request.maxBodyBytes = arrived;
  return request;
}

Future<void> _expectRefused(Response response) async {
  expect(response.status, 413);
  expect(await response.bodyText(), _refusal);
  expect(response.headers.contentType, 'application/json');
}

Future<void> _expectLength(Response response, int length) async {
  expect(response.status, 200, reason: await response.bodyText());
  expect(jsonDecode(await response.bodyText()), {'length': length});
}

void main() {
  group('the middleware only lowers the limit a request arrived with', () {
    for (final type in const [
      'application/json',
      'text/plain',
      'application/x-www-form-urlencoded',
    ]) {
      test('64 KiB arrived, 150 000 bytes of $type: 413', () async {
        final app = await _app();
        await _expectRefused(
          await app.handle(_post('/echo', 150000, type: type, arrived: _kib64)),
        );
        // The same without a Content-Length: refused when read.
        await _expectRefused(
          await app.handle(
            _post('/echo', 150000, type: type, arrived: _kib64, declare: false),
          ),
        );
        await _expectLength(
          await app.handle(_post('/echo', _kib64, type: type, arrived: _kib64)),
          _kib64,
        );
      });
    }

    test('the arrived limit also holds below a larger type limit set '
        'on the middleware', () async {
      final app = await _app(
        global: const [BodyLimitsMiddleware(json: 8 * _mib, other: 8 * _mib)],
      );
      await _expectRefused(
        await app.handle(_post('/echo', 150000, arrived: _kib64)),
      );
      await _expectRefused(
        await app.handle(
          _post('/echo', 150000, type: 'text/plain', arrived: _kib64),
        ),
      );
    });

    test('no arrived limit: the type limit applies', () async {
      final app = await _app();
      await _expectRefused(
        await app.handle(_post('/echo', _mib + 1, arrived: null)),
      );
      await _expectRefused(
        await app.handle(
          _post('/echo', _mib + 1, arrived: null, declare: false),
        ),
      );
      await _expectLength(
        await app.handle(_post('/echo', _mib, arrived: null)),
        _mib,
      );
    });

    test('a type limit below the arrived limit still lowers it', () async {
      final app = await _app();
      // 50 MiB arrived (the default), JSON limit 1 MiB.
      await _expectRefused(await app.handle(_post('/echo', _mib + 1)));
      await _expectLength(await app.handle(_post('/echo', _mib)), _mib);
    });
  });

  group('a route bodyLimit decides under the global middleware', () {
    test('a declared JSON body above the type limit is served', () async {
      final app = await _app();
      await _expectLength(await app.handle(_post('/wide', 2 * _mib)), 2 * _mib);
    });

    test('a body above the route limit is refused', () async {
      final app = await _app();
      await _expectRefused(await app.handle(_post('/wide', 4 * _mib + 1)));
      await _expectRefused(
        await app.handle(_post('/wide', 4 * _mib + 1, declare: false)),
      );
      await _expectLength(await app.handle(_post('/wide', 4 * _mib)), 4 * _mib);
    });

    test('a route limit above the arrived limit raises it', () async {
      final app = await _app();
      await _expectLength(
        await app.handle(_post('/wide', 150000, arrived: _kib64)),
        150000,
      );
      await _expectLength(
        await app.handle(
          _post('/wide', 150000, arrived: _kib64, declare: false),
        ),
        150000,
      );
      await _expectRefused(
        await app.handle(_post('/wide', 4 * _mib + 1, arrived: _kib64)),
      );
    });

    test('a body without Content-Length is refused when read, and served '
        'under the raised route limit', () async {
      final app = await _app();
      await _expectRefused(
        await app.handle(_post('/echo', 2 * _mib, declare: false)),
      );
      await _expectLength(
        await app.handle(_post('/wide', 2 * _mib, declare: false)),
        2 * _mib,
      );
    });
  });

  group('a declared length over the limit is still refused early', () {
    test('no route matches: 413, not 404', () async {
      final app = await _app();
      await _expectRefused(await app.handle(_post('/nowhere', _mib + 1)));
      // Within the limit the 404 is answered as before.
      expect((await app.handle(_post('/nowhere', 16))).status, 404);
    });

    test('no route matches the method: 413, not 405 or the OPTIONS '
        'answer', () async {
      final app = await _app();
      await _expectRefused(await app.handle(_post('/only-get', _mib + 1)));
      await _expectRefused(
        await app.handle(_post('/only-get', _mib + 1, method: 'OPTIONS')),
      );
      expect((await app.handle(_post('/only-get', 16))).status, 405);
    });

    test('no route matches and unmatched is set: 413, unmatched is not '
        'called', () async {
      final app = await _app();
      var forwarded = 0;
      app.kernel.unmatched = (request) async {
        forwarded++;
        return Response.text('forwarded');
      };
      await _expectRefused(await app.handle(_post('/nowhere', _mib + 1)));
      expect(forwarded, 0);
      expect(
        await (await app.handle(_post('/nowhere', 16))).bodyText(),
        'forwarded',
      );
      expect(forwarded, 1);
    });

    test('a route without bodyLimit: 413 before the route middleware and '
        'the handler', () async {
      final log = <String>[];
      final app = await _app(log: log);
      await _expectRefused(await app.handle(_post('/guarded', _mib + 1)));
      expect(log, isEmpty);
      await _expectRefused(
        await app.handle(_post('/guarded', 150000, arrived: _kib64)),
      );
      expect(log, isEmpty);
      expect((await app.handle(_post('/guarded', 16))).status, 200);
      expect(log, ['route', 'handler']);
    });

    test('the global middleware after it still runs before the '
        'refusal', () async {
      // The refusal waits for the route, so later global middleware sees
      // the request; nothing of the route runs.
      final log = <String>[];
      final app = await _app(
        global: [const BodyLimitsMiddleware(), _Tag('global', log)],
        log: log,
      );
      await _expectRefused(await app.handle(_post('/guarded', _mib + 1)));
      expect(log, ['global']);
    });
  });

  group('as route middleware', () {
    Future<Application> routed(List<String> log) => _app(
      global: const [],
      routes: (router) {
        router.post('/routed', _length).bodyLimit(10).middleware([
          const BodyLimitsMiddleware(),
        ]);
        router
            .post('/typed', (request) {
              log.add('handler');
              return _length(request);
            })
            .middleware([const BodyLimitsMiddleware()]);
      },
    );

    test('the route limit is used as it is', () async {
      final app = await routed(<String>[]);
      await _expectRefused(
        await app.handle(_post('/routed', 20, type: 'text/plain')),
      );
      await _expectLength(
        await app.handle(_post('/routed', 10, type: 'text/plain')),
        10,
      );
      // Also above the limit the request arrived with.
      await _expectLength(
        await app.handle(_post('/routed', 8, type: 'text/plain', arrived: 4)),
        8,
      );
    });

    test('without a route limit it lowers the arrived limit and refuses at '
        'once', () async {
      final log = <String>[];
      final app = await routed(log);
      await _expectRefused(
        await app.handle(_post('/typed', 150000, arrived: _kib64)),
      );
      await _expectRefused(await app.handle(_post('/typed', _mib + 1)));
      expect(log, isEmpty);
      await _expectLength(await app.handle(_post('/typed', _mib)), _mib);
      expect(log, ['handler']);
    });
  });

  group('without the middleware nothing changes', () {
    test('a declared length over the limit reaches a handler that never '
        'reads the body', () async {
      final app = await _app(global: const []);
      final request = Request.fake(
        method: 'POST',
        path: '/ignore',
        body: 'x',
        headers: {'content-length': '${60 * _mib}'},
      );
      final response = await app.handle(request);
      expect(response.status, 200);
      expect(await response.bodyText(), 'ignored');
      // No route: the 404 as before.
      final missing = Request.fake(
        method: 'POST',
        path: '/nowhere',
        body: 'x',
        headers: {'content-length': '${60 * _mib}'},
      );
      expect((await app.handle(missing)).status, 404);
    });

    test('a handler that reads is refused by the arrived limit', () async {
      final app = await _app(global: const []);
      await _expectRefused(
        await app.handle(_post('/echo', 150000, arrived: _kib64)),
      );
      // main: the engine limits a JSON body to 1 MiB without the middleware
      // (HTTP_MAX_JSON_BODY), so the 2 MiB body 1.x serves is text here.
      await _expectLength(
        await app.handle(_post('/echo', 2 * _mib, type: 'text/plain')),
        2 * _mib,
      );
      await _expectRefused(await app.handle(_post('/echo', 2 * _mib)));
      await _expectLength(
        await app.handle(_post('/wide', 150000, arrived: _kib64)),
        150000,
      );
    });
  });

  // Every application ends its global middleware with
  // MethodOverrideMiddleware, which reads a POST form before routing on a
  // path that also has a PUT, PATCH or DELETE route.
  group('a form read for _method before routing', () {
    /// `/form` with a POST and a PUT route; [seen] collects the exceptions
    /// the handler reported or rendered and the handlers that ran.
    Future<Application> forms(
      List<String> seen, {
      int? postLimit,
      int? putLimit,
      List<Middleware> global = const <Middleware>[BodyLimitsMiddleware()],
      bool methodOverride = true,
    }) async {
      Future<Object?> Function(Request) handler(String via) => (request) async {
        seen.add(via);
        final input = await request.all();
        final file = await request.file('file');
        return <String, Object?>{
          'via': via,
          'method': request.method,
          'data': (input['data'] as String?)?.length,
          'file': file?.size,
          'limit': request.maxBodyBytes,
        };
      };

      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withRouting(
            apiPrefix: '',
            api: (router) {
              final post = router.post('/form', handler('POST'));
              final put = router.put('/form', handler('PUT'));
              if (postLimit != null) {
                post.bodyLimit(postLimit);
              }
              if (putLimit != null) {
                put.bodyLimit(putLimit);
              }
            },
          )
          .withMiddleware((m) {
            m.methodOverride = methodOverride;
            m.use(global);
          })
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      app.kernel.exceptions
        ..report<PayloadTooLargeHttpException>(
          (error, stackTrace, request) => seen.add('reported'),
        )
        ..render<PayloadTooLargeHttpException>((error, request) {
          seen.add('rendered');
          return null;
        });
      return app;
    }

    /// A urlencoded POST whose `data` field is [size] bytes.
    Request form(
      int size, {
      String? method = 'PUT',
      int? arrived = Request.defaultMaxBodyBytes,
      bool declare = true,
    }) {
      final request = Request.fake(
        method: 'POST',
        path: '/form',
        form: {'_method': ?method, 'data': 'x' * size},
      );
      if (!declare) {
        request.headers.remove('content-length');
      }
      request.maxBodyBytes = arrived;
      return request;
    }

    Future<void> expectServed(
      Response response,
      String via, {
      int? data,
      int? file,
      required int limit,
    }) async {
      expect(response.status, 200, reason: await response.bodyText());
      expect(jsonDecode(await response.bodyText()), {
        'via': via,
        'method': via,
        'data': data,
        'file': file,
        'limit': limit,
      });
    }

    Future<void> expectDirectRefusal(Response response) async {
      final direct = laravelErrorResponse(<String, Object?>{
        'message': const PayloadTooLargeHttpException().message,
      }, status: 413);
      expect(response.status, 413);
      expect(await response.bodyText(), await direct.bodyText());
      expect(
        response.headers.toSingleValueMap(),
        direct.headers.toSingleValueMap(),
      );
    }

    test('the PUT route bodyLimit serves a declared 2 MiB form', () async {
      final seen = <String>[];
      final app = await forms(seen, putLimit: 4 * _mib);
      await expectServed(
        await app.handle(form(2 * _mib)),
        'PUT',
        data: 2 * _mib,
        limit: 4 * _mib,
      );
      expect(seen, ['PUT']);
    });

    // main: MethodOverrideMiddleware reads the form under the loosest limit
    // of the routes on the path and the declared length fails that read,
    // so the same 413 comes through the exception handler; 1.x answers it
    // directly. The body stays unread either way.
    test('no route has a bodyLimit: the same 413, through the exception '
        'handler', () async {
      final seen = <String>[];
      final app = await forms(seen);
      final request = form(2 * _mib);
      await expectDirectRefusal(await app.handle(request));
      expect(seen, ['reported', 'rendered']);
      expect(request.bodyBytesRead, 0);
      expect(request.method, 'POST', reason: '_method was not read');
    });

    test('only the POST route has a bodyLimit: POST is served, _method=PUT '
        'is refused by the kernel under the lowered limit', () async {
      final seen = <String>[];
      final app = await forms(seen, postLimit: 4 * _mib);
      await expectServed(
        await app.handle(form(2 * _mib, method: null)),
        'POST',
        data: 2 * _mib,
        limit: 4 * _mib,
      );
      expect(seen, ['POST']);
      seen.clear();
      final request = form(2 * _mib);
      await expectDirectRefusal(await app.handle(request));
      expect(seen, isEmpty);
      // The form was read under the POST route's limit to find _method;
      // the PUT route it led to keeps the lowered limit.
      expect(request.method, 'PUT');
      expect(request.maxBodyBytes, _mib);
    });

    // main: through the exception handler, as above.
    test('a declared length over the largest route limit: the same 413, '
        'unread', () async {
      final seen = <String>[];
      final app = await forms(seen, postLimit: 2 * _mib, putLimit: 4 * _mib);
      final request = form(4 * _mib + 1);
      await expectDirectRefusal(await app.handle(request));
      expect(seen, ['reported', 'rendered']);
      expect(request.bodyBytesRead, 0);
      expect(request.method, 'POST', reason: '_method was not read');
      seen.clear();
      // Between the two limits the larger one reads it.
      await expectServed(
        await app.handle(form(3 * _mib)),
        'PUT',
        data: 3 * _mib,
        limit: 4 * _mib,
      );
    });

    test('a multipart form over the arrived limit is served by the PUT '
        'route bodyLimit', () async {
      final seen = <String>[];
      final app = await forms(seen, putLimit: 4 * _mib);
      Request upload() => Request.fake(
        method: 'POST',
        path: '/form',
        form: const {'_method': 'PUT', 'data': 'abc'},
        files: {
          'file': UploadedFile.fromBytes(
            List<int>.filled(150000, 0x61),
            name: 'a.txt',
          ),
        },
      )..maxBodyBytes = _kib64;
      await expectServed(
        await app.handle(upload()),
        'PUT',
        data: 3,
        file: 150000,
        limit: 4 * _mib,
      );
      expect(seen, ['PUT']);
      seen.clear();
      // main: through the exception handler, as above.
      final plain = await forms(seen);
      await expectDirectRefusal(await plain.handle(upload()));
      expect(seen, ['reported', 'rendered']);
    });

    // main: through the exception handler, as above.
    test('MethodOverrideMiddleware without a router: the same 413, '
        'unread', () async {
      final seen = <String>[];
      final app = await forms(
        seen,
        putLimit: 4 * _mib,
        methodOverride: false,
        global: const [BodyLimitsMiddleware(), MethodOverrideMiddleware()],
      );
      final request = form(2 * _mib);
      await expectDirectRefusal(await app.handle(request));
      expect(seen, ['reported', 'rendered']);
      expect(request.bodyBytesRead, 0);
      expect(request.method, 'POST', reason: '_method was not read');
      seen.clear();
      // Within the limit it reads the form as before.
      await expectServed(
        await app.handle(form(1000)),
        'PUT',
        data: 1000,
        limit: 4 * _mib,
      );
    });

    test('a form within the limits is read as before', () async {
      final seen = <String>[];
      final app = await forms(seen);
      await expectServed(
        await app.handle(form(1000)),
        'PUT',
        data: 1000,
        limit: _mib,
      );
      await expectServed(
        await app.handle(form(1000, method: null)),
        'POST',
        data: 1000,
        limit: _mib,
      );
      expect(seen, ['PUT', 'POST']);
    });

    // main: MethodOverrideMiddleware already reads a form under the loosest
    // bodyLimit of the routes on its path, so the form 1.x refuses here (it
    // reads under the lowered limit when nothing is declared) is served.
    test('a form without Content-Length is read under the loosest route '
        'limit', () async {
      final seen = <String>[];
      final app = await forms(seen, putLimit: 4 * _mib);
      await expectServed(
        await app.handle(form(2 * _mib, declare: false)),
        'PUT',
        data: 2 * _mib,
        limit: 4 * _mib,
      );
      expect(seen, ['PUT']);
      seen.clear();
      // Over every limit on the path it is refused while read.
      final response = await app.handle(form(4 * _mib + 1, declare: false));
      expect(response.status, 413);
      expect(await response.bodyText(), _refusal);
      expect(seen, ['reported', 'rendered']);
      seen.clear();
      // No route limit: the middleware's form limit, as on 1.x.
      final plain = await forms(seen);
      final refused = await plain.handle(form(2 * _mib, declare: false));
      expect(refused.status, 413);
      expect(await refused.bodyText(), _refusal);
      expect(seen, ['reported', 'rendered']);
    });
  });

  group('the middleware replaces the engine type limits', () {
    const wide = BodyLimitsMiddleware(json: 5 * _mib, form: 3 * _mib);

    test('json: 5 MiB above the engine 1 MiB serves a 2 MiB JSON '
        'body', () async {
      final app = await _app(global: const [wide]);
      await _expectLength(await app.handle(_post('/echo', 2 * _mib)), 2 * _mib);
      await _expectLength(
        await app.handle(_post('/echo', 2 * _mib, declare: false)),
        2 * _mib,
      );
      await _expectRefused(await app.handle(_post('/echo', 5 * _mib + 1)));
      await _expectRefused(
        await app.handle(_post('/echo', 5 * _mib + 1, declare: false)),
      );
      // A form likewise (no PUT route on the path: it is not read early).
      const form = 'application/x-www-form-urlencoded';
      await _expectLength(
        await app.handle(_post('/echo', 2 * _mib, type: form)),
        2 * _mib,
      );
      await _expectRefused(
        await app.handle(_post('/echo', 3 * _mib + 1, type: form)),
      );
    });

    test('the same under a 512 KiB ceiling is refused', () async {
      const ceiling = 512 << 10;
      final app = await _app(global: const [wide]);
      await _expectRefused(
        await app.handle(_post('/echo', 2 * _mib, arrived: ceiling)),
      );
      await _expectRefused(
        await app.handle(
          _post('/echo', 2 * _mib, arrived: ceiling, declare: false),
        ),
      );
      await _expectRefused(
        await app.handle(_post('/echo', ceiling + 1, arrived: ceiling)),
      );
      await _expectLength(
        await app.handle(_post('/echo', ceiling, arrived: ceiling)),
        ceiling,
      );
      // The route bodyLimit is not held by the ceiling.
      await _expectLength(
        await app.handle(_post('/wide', 2 * _mib, arrived: ceiling)),
        2 * _mib,
      );
    });

    test('no ceiling (HTTP_MAX_BODY=0): the middleware limits alone', () async {
      final app = await _app(global: const [wide]);
      final request = _post('/echo', 2 * _mib, arrived: null);
      await _expectLength(await app.handle(request), 2 * _mib);
      expect(request.maxBodyBytes, 5 * _mib);
      await _expectRefused(
        await app.handle(_post('/echo', 5 * _mib + 1, arrived: null)),
      );
      await _expectRefused(
        await app.handle(
          _post('/echo', 5 * _mib + 1, arrived: null, declare: false),
        ),
      );
    });

    test('as route middleware too, and there also under the '
        'ceiling', () async {
      final app = await _app(
        global: const [],
        routes: (router) =>
            router.post('/typed', _length).middleware(const [wide]),
      );
      await _expectLength(
        await app.handle(_post('/typed', 2 * _mib)),
        2 * _mib,
      );
      await _expectRefused(await app.handle(_post('/typed', 5 * _mib + 1)));
      await _expectRefused(
        await app.handle(_post('/typed', 2 * _mib, arrived: 512 << 10)),
      );
    });
  });

  group('a body read before the global middleware', () {
    test('over the limit: refused once routed, unless the route bodyLimit '
        'allows it', () async {
      final app = await _app(
        global: const [_ReadBody(), BodyLimitsMiddleware(other: 10)],
      );
      Request chunked(String path) =>
          _post(path, 20, type: 'text/plain', declare: false);
      await _expectRefused(await app.handle(chunked('/nowhere')));
      await _expectRefused(await app.handle(chunked('/echo')));
      await _expectLength(await app.handle(chunked('/wide')), 20);
      expect(
        (await app.handle(
          _post('/nowhere', 10, type: 'text/plain', declare: false),
        )).status,
        404,
      );
    });
  });

  group('given a request without the kernel', () {
    Future<Response> run(
      Request request, {
      BodyLimitsMiddleware middleware = const BodyLimitsMiddleware(
        json: 8 * _mib,
      ),
    }) => middleware.handle(request, (_) async => Response.text('next'));

    RouteEntry route({int? bodyLimit}) {
      final router = Router();
      final entry = router.post('/echo', _length);
      if (bodyLimit != null) {
        entry.bodyLimit(bodyLimit);
      }
      router.compile(MiddlewareRegistry());
      return router.lookup('POST', '/echo')!.value;
    }

    test('the limit the request has is the ceiling', () async {
      final low = _post('/echo', 16, arrived: _kib64);
      expect(await (await run(low)).bodyText(), 'next');
      expect(low.maxBodyBytes, _kib64);
      final high = _post('/echo', 16);
      await run(high);
      expect(high.maxBodyBytes, 8 * _mib);
      final none = _post('/echo', 16, arrived: null);
      await run(none);
      expect(none.maxBodyBytes, 8 * _mib);
    });

    test('no route: a declared length over the limit goes on, and is '
        'refused when read', () async {
      final request = _post('/echo', 150000, arrived: _kib64);
      expect(await (await run(request)).bodyText(), 'next');
      expect(request.maxBodyBytes, _kib64);
      await expectLater(
        request.bytes(),
        throwsA(isA<PayloadTooLargeHttpException>()),
      );
    });

    test('a route without bodyLimit: 413 at once', () async {
      final request = _post('/echo', 150000, arrived: _kib64)
        ..bindRoute(route(), const {});
      await _expectRefused(await run(request));
      final fits = _post('/echo', _kib64, arrived: _kib64)
        ..bindRoute(route(), const {});
      expect(await (await run(fits)).bodyText(), 'next');
    });

    test('a route bodyLimit is used as it is', () async {
      final request = _post('/echo', 150000, arrived: _kib64)
        ..bindRoute(route(bodyLimit: 4 * _mib), const {});
      expect(await (await run(request)).bodyText(), 'next');
      expect(request.maxBodyBytes, 4 * _mib);
      final over = _post('/echo', 4 * _mib + 1)
        ..bindRoute(route(bodyLimit: 4 * _mib), const {});
      await _expectRefused(await run(over));
    });
  });

  test('the 413 answer is the one the middleware always gave', () async {
    final before = laravelErrorResponse(<String, Object?>{
      'message': const PayloadTooLargeHttpException().message,
    }, status: 413);
    final expected = await before.bodyText();
    expect(expected, _refusal);
    final app = await _app();
    for (final request in [
      _post('/nowhere', _mib + 1),
      _post('/echo', _mib + 1),
      _post('/guarded', _mib + 1),
      _post('/wide', 4 * _mib + 1),
    ]) {
      final response = await app.handle(request);
      expect(response.status, before.status);
      expect(await response.bodyText(), expected);
      expect(
        response.headers.toSingleValueMap(),
        before.headers.toSingleValueMap(),
      );
    }
    // APP_DEBUG adds nothing to it.
    final debug = await _app();
    debug.kernel.exceptions.debug = true;
    for (final request in [
      _post('/nowhere', _mib + 1),
      _post('/echo', _mib + 1),
      _post('/wide', 4 * _mib + 1),
      _post('/echo', 2 * _mib, declare: false),
    ]) {
      await _expectRefused(await debug.handle(request));
    }
  });

  group('on a socket, HTTP_MAX_BODY of 64 KiB', () {
    Future<ServerEngine> serve() async {
      final app = await _app();
      final engine = ServerEngine(
        app,
        const ServeOptions(
          host: '127.0.0.1',
          port: 0,
          handleSignals: false,
          maxBodyBytes: _kib64,
        ),
        kernel: app.kernel,
        logger: Logger(minimumLevel: .critical),
      );
      await engine.start();
      addTearDown(engine.stop);
      return engine;
    }

    /// Sends [size] bytes as JSON, declared or chunked, and reads the reply
    /// until the server closes or goes quiet for a second. A server that
    /// refuses a declared body answers without reading it, so the write may
    /// fail.
    Future<String> send(
      ServerEngine engine,
      String path,
      int size, {
      bool chunked = false,
    }) async {
      final socket = await Socket.connect('127.0.0.1', engine.port!);
      final received = BytesBuilder();
      final closed = Completer<void>();
      void finish() {
        if (!closed.isCompleted) {
          closed.complete();
        }
      }

      socket
          .timeout(
            const Duration(seconds: 1),
            onTimeout: (sink) => sink.close(),
          )
          .listen(
            received.add,
            onError: (Object _) => finish(),
            onDone: finish,
            cancelOnError: true,
          );
      socket.write(
        'POST $path HTTP/1.1\r\nHost: localhost\r\n'
        'Content-Type: application/json\r\n'
        '${chunked ? 'Transfer-Encoding: chunked' : 'Content-Length: $size'}'
        '\r\nConnection: close\r\n\r\n',
      );
      if (chunked) {
        socket.write('${size.toRadixString(16)}\r\n');
      }
      socket.add(List<int>.filled(size, 0x61));
      if (chunked) {
        socket.write('\r\n0\r\n\r\n');
      }
      try {
        await socket.flush();
      } on SocketException {
        // Answered and closed before the whole body was sent.
      }
      await closed.future;
      socket.destroy();
      final deadline = DateTime.now().add(const Duration(seconds: 3));
      while (engine.inFlight != 0 && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(engine.inFlight, 0, reason: 'the slot is released');
      return utf8.decode(received.takeBytes(), allowMalformed: true);
    }

    test('a declared JSON body of 150 000 bytes is refused', () async {
      final engine = await serve();
      final reply = await send(engine, '/echo', 150000);
      expect(reply, startsWith('HTTP/1.1 413'));
      expect(reply, endsWith(_refusal));
      expect(
        await send(engine, '/echo', _kib64),
        contains('{"length":$_kib64}'),
      );
    });

    test('a chunked JSON body of 150 000 bytes is not served', () async {
      final engine = await serve();
      final reply = await send(engine, '/echo', 150000, chunked: true);
      // The read stops at the limit and the server answers 413. It then
      // closes a connection that still holds unread body, which can cost
      // the client the answer (a reset): the handler never has the body.
      expect(reply, anyOf(isEmpty, startsWith('HTTP/1.1 413')));
      expect(reply, isNot(contains('"length"')));
      expect(
        await send(engine, '/echo', _kib64, chunked: true),
        contains('{"length":$_kib64}'),
      );
    });

    test('the route bodyLimit serves it, declared or chunked', () async {
      final engine = await serve();
      expect(
        await send(engine, '/wide', 150000),
        contains('{"length":150000}'),
      );
      expect(
        await send(engine, '/wide', 150000, chunked: true),
        contains('{"length":150000}'),
      );
    });
  });
}
