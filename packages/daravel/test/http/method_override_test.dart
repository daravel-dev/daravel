import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

void main() {
  late Directory base;

  Future<TestClient> boot({bool enabled = true}) async {
    base = Directory.systemTemp.createTempSync('daravel_override');
    final app = Application.configure(basePath: base.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withMiddleware((middleware) => middleware.methodOverride = enabled)
        .withRouting(
          web: (router) {
            Map<String, Object?> seen(Request request) => {
              'method': request.method,
              'original': request.originalMethod,
            };
            router.post('/items', seen);
            router.put('/items', seen);
            router.delete('/items', seen);
          },
        )
        .create();
    await app.boot();
    addTearDown(() async {
      await app.shutdown();
      base.deleteSync(recursive: true);
    });
    return TestClient(app);
  }

  test('_method in a form', () async {
    final client = await boot();
    final response = await client.post('/items', form: {'_method': 'put'});
    expect(response.jsonMap, {'method': 'PUT', 'original': 'POST'});
  });

  test('_method in a multipart form', () async {
    final client = await boot();
    final response = await client.post(
      '/items',
      form: {'_method': 'DELETE'},
      files: {'a': UploadedFile.fake.withContent('a.txt', 'x')},
    );
    expect(response.jsonMap['method'], 'DELETE');
  });

  test('X-HTTP-Method-Override', () async {
    final client = await boot();
    final response = await client.post(
      '/items',
      headers: {'x-http-method-override': 'DELETE'},
    );
    expect(response.jsonMap['method'], 'DELETE');
  });

  test('_method in the query string', () async {
    final client = await boot();
    final response = await client.post('/items?_method=PUT');
    expect(response.jsonMap['method'], 'PUT');
  });

  test('a JSON body is not read for it', () async {
    final client = await boot();
    final response = await client.post('/items', json: {'_method': 'PUT'});
    expect(response.jsonMap['method'], 'POST');
  });

  test('other verbs and other methods are left alone', () async {
    final client = await boot();
    for (final verb in ['GET', 'HEAD', 'TRACE', 'CONNECT', 'FOO']) {
      final response = await client.post('/items', form: {'_method': verb});
      expect(response.jsonMap['method'], 'POST', reason: verb);
    }
    final put = await client.put(
      '/items',
      headers: {'x-http-method-override': 'DELETE'},
    );
    expect(put.jsonMap['method'], 'PUT');
  });

  test('it can be turned off', () async {
    final client = await boot(enabled: false);
    final response = await client.post('/items', form: {'_method': 'PUT'});
    expect(response.jsonMap['method'], 'POST');
  });
}
