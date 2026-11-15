import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

void main() {
  Future<TestClient> boot() async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.critical)
        .withRouting(
          apiPrefix: '',
          api: (router) {
            Object seen(Request request) => request.method;
            router.post('/post', seen);
            router.post('/both', seen);
            router.put('/both', seen);
            router.patch('/both', seen);
            router.delete('/both', seen);
            router.post('/hosted', seen);
            router.put('/hosted', seen).domain('other.test');
            router.post('/items/{id}', seen);
            router.put('/items/{id}', seen);
          },
        )
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    return TestClient(app);
  }

  test('forms on a POST-only path keep their method', () async {
    final client = await boot();
    final response = await client.post('/post', form: {'_method': 'PUT'});
    expect(response.body, 'POST');
  });

  test('each form method reaches a route on its path', () async {
    final client = await boot();
    for (final method in ['PUT', 'PATCH', 'DELETE']) {
      final response = await client.post('/both', form: {'_method': method});
      expect(response.body, method);
    }
    final response = await client.post('/items/42', form: {'_method': 'PUT'});
    expect(response.body, 'PUT');
  });

  test(
    'a candidate on another host leaves the form for its POST route',
    () async {
      final client = await boot();
      final response = await client.post('/hosted', form: {'_method': 'PUT'});
      expect(response.body, 'POST');
    },
  );

  test('header and query overrides still apply on a POST-only path', () async {
    final client = await boot();
    final header = await client.post(
      '/post',
      headers: {'x-http-method-override': 'PUT'},
    );
    final query = await client.post('/post?_method=PUT');
    expect(header.status, 405);
    expect(query.status, 405);
  });

  test(
    'standalone middleware without a router still reads form methods',
    () async {
      final request = Request.fake(method: 'POST', form: {'_method': 'PUT'});
      await const MethodOverrideMiddleware().handle(
        request,
        (request) async => Response.text(request.method),
      );
      expect(request.method, 'PUT');
    },
  );
}
