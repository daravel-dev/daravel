import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class _Trace implements Middleware {
  const _Trace(this.label);

  final String label;

  @override
  Future<Response> handle(Request request, Next next) async {
    final trace = request.attributes.putIfAbsent(
      'trace',
      () => <String>[],
    ) as List<String>;
    trace.add(label);
    final response = await next(request);
    return response.withHeader('x-trace-$label', 'done');
  }
}

Application _buildApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(<String, String>{
          'APP_ENV': 'testing',
          'APP_NAME': 'KernelTest',
          'DB_DATABASE': ':memory:',
        })
        .withRouting(
          api: (r) {
            r.get('/text', (_) => 'hello');
            r.get(
              '/json',
              (_) => <String, Object?>{
                'a': 1,
                'when': DateTime.utc(2026, 1, 2, 3, 4, 5),
              },
            );
            r.get('/null', (_) => null);
            r.get(
              '/response',
              (_) => Response.created(<String, Object?>{
                'id': 1,
              }, location: '/x/1'),
            );
            r.get('/boom', (_) => throw StateError('boom'));
            r.get('/unhandled', (_) => throw UnimplementedError('nope'));
            r.get('/abort', (_) => abort(418, "I'm a teapot"));
            r
                .get(
                  '/order',
                  (req) => (req.attributes['trace']! as List<String>).join(','),
                )
                .middleware(<Object>[const _Trace('route')]);
            r.get(
              '/users/{id}',
              (req) => <String, Object?>{'id': req.param<int>('id')},
            );
            r.post(
              '/echo',
              (req) async => <String, Object?>{
                'name': await req.input<String>('name'),
                'nested': await req.input<int>('meta.count'),
                'q': req.query['q'],
                'bearer': req.bearerToken(),
              },
            );
          },
          health: '/up',
        )
        .withMiddleware(
          (m) => m.use(<Middleware>[
            const RequestIdMiddleware(),
            const _Trace('global'),
          ]),
        )
        .withExceptions((e) {
          e.render<StateError>(
            (error, req) => Response.json(<String, Object?>{
              'message': 'custom: ${error.message}',
            }, status: 500),
          );
          e.dontReport<StateError>();
          e.dontReport<UnimplementedError>();
        })
        .create();

void main() {
  late Application app;

  setUp(() async {
    app = _buildApp();
    await app.boot();
  });

  tearDown(() => app.shutdown());

  Future<Map<String, Object?>> jsonOf(Response response) async =>
      jsonDecode(await response.bodyText()) as Map<String, Object?>;

  test(
    'string results become text responses with the request id echoed',
    () async {
      final response = await app.handle(
        Request.fake(path: '/api/text', id: 'req-1'),
      );
      expect(response.status, 200);
      expect(response.headers.contentType, 'text/plain; charset=utf-8');
      expect(await response.bodyText(), 'hello');
      expect(response.headers['x-request-id'], 'req-1');
      expect(response.headers['x-trace-global'], 'done');
    },
  );

  test('maps become JSON with ISO-8601 UTC dates', () async {
    final response = await app.handle(Request.fake(path: '/api/json'));
    expect(response.headers.contentType, 'application/json');
    expect(await jsonOf(response), <String, Object?>{
      'a': 1,
      'when': '2026-01-02T03:04:05.000000Z',
    });
  });

  test('null results become an empty 200', () async {
    final response = await app.handle(Request.fake(path: '/api/null'));
    expect(response.status, 200);
    expect(await response.bodyBytes(), isEmpty);
  });

  test('Response objects pass through untouched', () async {
    final response = await app.handle(Request.fake(path: '/api/response'));
    expect(response.status, 201);
    expect(response.headers['location'], '/x/1');
    expect(await jsonOf(response), <String, Object?>{'id': 1});
  });

  test('unknown routes render a Laravel-style 404', () async {
    final response = await app.handle(Request.fake(path: '/api/nope'));
    expect(response.status, 404);
    expect(await jsonOf(response), <String, Object?>{
      'message': 'The route api/nope could not be found.',
    });
  });

  test('wrong methods render 405 with an Allow header', () async {
    final response = await app.handle(
      Request.fake(method: 'POST', path: '/api/text'),
    );
    expect(response.status, 405);
    expect(response.headers['allow'], 'GET, HEAD');
    expect(
      (await jsonOf(response))['message'],
      'The POST method is not supported for route api/text. Supported methods: GET, HEAD.',
    );
  });

  test('OPTIONS answers with Allow and HEAD strips the body', () async {
    final options = await app.handle(
      Request.fake(method: 'OPTIONS', path: '/api/text'),
    );
    expect(options.status, 200);
    expect(options.headers['allow'], 'GET, HEAD');

    final head = await app.handle(
      Request.fake(method: 'HEAD', path: '/api/text'),
    );
    expect(head.status, 200);
    expect(await head.bodyBytes(), isEmpty);
    expect(head.contentLengthOverride, 5);
  });

  test('custom renderers and HttpExceptions are honoured', () async {
    final custom = await app.handle(Request.fake(path: '/api/boom'));
    expect(custom.status, 500);
    expect(await jsonOf(custom), <String, Object?>{'message': 'custom: boom'});

    final teapot = await app.handle(Request.fake(path: '/api/abort'));
    expect(teapot.status, 418);
    expect(await jsonOf(teapot), <String, Object?>{'message': "I'm a teapot"});

    final unhandled = await app.handle(Request.fake(path: '/api/unhandled'));
    expect(unhandled.status, 500);
    expect(await jsonOf(unhandled), <String, Object?>{
      'message': 'Server Error',
    });
  });

  test('global middleware runs before route middleware', () async {
    final response = await app.handle(Request.fake(path: '/api/order'));
    expect(await response.bodyText(), 'global,route');
    expect(response.headers['x-trace-route'], 'done');
  });

  test('typed route parameters parse or 404', () async {
    expect(
      await jsonOf(await app.handle(Request.fake(path: '/api/users/42'))),
      <String, Object?>{'id': 42},
    );
    expect(
      (await app.handle(Request.fake(path: '/api/users/abc'))).status,
      404,
    );
  });

  test('input merges JSON body (dot notation) and query', () async {
    final response = await app.handle(
      Request.fake(
        method: 'POST',
        path: '/api/echo?q=1',
        json: <String, Object?>{
          'name': 'Ana',
          'meta': <String, Object?>{'count': 3},
        },
        headers: <String, String>{'authorization': 'Bearer secret'},
      ),
    );
    expect(await jsonOf(response), <String, Object?>{
      'name': 'Ana',
      'nested': 3,
      'q': '1',
      'bearer': 'secret',
    });
  });

  test('malformed JSON bodies yield 400', () async {
    final response = await app.handle(
      Request.fake(
        method: 'POST',
        path: '/api/echo',
        body: '{oops',
        headers: <String, String>{'content-type': 'application/json'},
      ),
    );
    expect(response.status, 400);
  });

  test('health endpoint reports ok and 503 while draining', () async {
    final ok = await app.handle(Request.fake(path: '/up'));
    expect(ok.status, 200);
    expect((await jsonOf(ok))['status'], 'ok');
    expect((await jsonOf(ok))['app'], 'KernelTest');

    app.markDraining();
    final draining = await app.handle(Request.fake(path: '/up'));
    expect(draining.status, 503);
  });
}
