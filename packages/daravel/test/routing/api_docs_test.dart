import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

void main() {
  Future<(Application, TestClient)> boot(Map<String, String> env) async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({'DB_DATABASE': ':memory:', 'APP_NAME': 'Shop', ...env})
        .withRouting(
          api: (router) {
            router
                .post('/orders', (_) => null)
                .rules(const {'sku': 'required|string'})
                .name('orders.store');
          },
        )
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    return (app, TestClient(app));
  }

  test('local: /docs/api serves the reference and /docs/api.json the '
      'document of the routes', () async {
    final (_, client) = await boot({'APP_ENV': 'local'});
    (await client.get('/docs/api'))
      ..assertOk()
      ..assertHeader('content-type', 'text/html; charset=utf-8')
      ..assertSee('<title>Shop API</title>')
      ..assertSee('data-url="/docs/api.json"')
      ..assertSee('@scalar/api-reference@');
    final spec = await client.get('/docs/api.json');
    spec.assertOk();
    final document = jsonDecode(spec.body) as Map<String, Object?>;
    expect(document['openapi'], startsWith('3.1'));
    expect((document['info']! as Map)['title'], 'Shop API');
    final paths = (document['paths']! as Map).keys;
    expect(paths, contains('/api/orders'));
    expect(
      paths.where((p) => '$p'.startsWith('/docs')),
      isEmpty,
      reason: 'the docs routes leave themselves out',
    );
  });

  test('off outside local unless API_DOCS; API_DOCS_PATH moves it', () async {
    final (_, production) = await boot({
      'APP_ENV': 'production',
      'APP_KEY': 'base64:${base64Encode(List.filled(32, 1))}',
    });
    (await production.get('/docs/api')).assertNotFound();
    (await production.get('/docs/api.json')).assertNotFound();

    final (_, local) = await boot({'APP_ENV': 'local', 'API_DOCS': 'false'});
    (await local.get('/docs/api')).assertNotFound();

    final (_, staging) = await boot({
      'APP_ENV': 'staging',
      'API_DOCS': 'true',
      'API_DOCS_PATH': '/reference',
    });
    (await staging.get('/reference')).assertOk();
    (await staging.get('/reference.json')).assertOk();
    (await staging.get('/docs/api')).assertNotFound();
  });
}
