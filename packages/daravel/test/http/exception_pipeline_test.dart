import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// `Illuminate\Pipeline\Pipeline::carry()`: an exception becomes a response
/// at the layer it was thrown in, and every outer middleware finishes.
void main() {
  late Directory base;
  late Application app;
  late TestClient client;
  late List<String> seen;
  late List<Object> caught;
  late int reported;

  Middleware spy(String name) => FunctionalMiddleware((request, next) async {
    final response = await next(request);
    seen.add('$name:${response.status}');
    if (name == 'outer' && response.exception != null) {
      caught.add(response.exception!);
    }
    return response.withHeader('x-$name', 'yes');
  });

  setUp(() async {
    seen = [];
    caught = [];
    reported = 0;
    base = Directory.systemTemp.createTempSync('daravel_pipeline');
    app = Application.configure(basePath: base.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withExceptions((exceptions) {
          exceptions.report<StateError>((error, trace, request) {
            reported++;
          });
        })
        .withMiddleware((middleware) => middleware.use([spy('global')]))
        .withRouting(
          web: (router) {
            router
                .get('/handler', (_) {
                  throw const HttpException(403, 'no');
                })
                .middleware([spy('outer'), spy('inner')]);
            router
                .get('/crash', (_) {
                  throw StateError('boom');
                })
                .middleware([spy('outer'), spy('inner')]);
            router.get('/middleware', (_) => 'never').middleware([
              spy('outer'),
              FunctionalMiddleware((request, next) {
                throw const HttpException(401, 'no');
              }),
              spy('inner'),
            ]);
            router
                .post('/validate', (request) async {
                  await request.validate({'a': 'required'});
                  return 'ok';
                })
                .middleware([spy('outer')]);
            router
                .get('/limited', (_) {
                  throw const HttpException(403, 'no');
                })
                .middleware(['throttle:5,1']);
            router.get('/ok', (_) => 'ok').middleware(['throttle:5,1']);
          },
        )
        .create();
    await app.boot();
    client = TestClient(app);
  });

  tearDown(() async {
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  test('every middleware finishes around a handler that throws', () async {
    final response = await client.get('/handler');
    expect(response.status, 403);
    expect(seen, ['inner:403', 'outer:403', 'global:403']);
    for (final name in ['x-inner', 'x-outer', 'x-global']) {
      expect(response.headers.first(name), 'yes', reason: name);
    }
  });

  test('a throwing middleware reaches only the ones outside it', () async {
    final response = await client.get('/middleware');
    expect(response.status, 401);
    expect(seen, ['outer:401', 'global:401']);
  });

  test('a validation failure is a 422 the middleware see', () async {
    final response = await client.post('/validate', json: <String, Object?>{});
    expect(response.status, 422);
    expect(seen, ['outer:422', 'global:422']);
  });

  test('an unhandled error is reported once and is a 500', () async {
    final response = await client.get('/crash');
    expect(response.status, 500);
    expect(reported, 1);
    expect(seen, ['inner:500', 'outer:500', 'global:500']);
  });

  test('an outer middleware sees the exception on the response', () async {
    await client.get('/handler');
    await client.get('/crash');
    expect(caught, [isA<HttpException>(), isA<StateError>()]);
  });

  test('throttle headers survive an exception', () async {
    final response = await client.get('/limited');
    expect(response.status, 403);
    expect(response.headers.first('x-ratelimit-limit'), '5');
    expect(response.headers.first('x-ratelimit-remaining'), '4');
  });

  test('withoutExceptionHandling still reaches the test', () {
    expect(
      client.withoutExceptionHandling().get('/crash'),
      throwsA(isA<StateError>()),
    );
  });
}
