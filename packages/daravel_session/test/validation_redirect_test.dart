import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_session/daravel_session.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// `Illuminate\Foundation\Exceptions\Handler::invalid()` for browsers and
/// Inertia, `invalidJson()` for API clients.
void main() {
  late Directory base;
  late Application app;
  late TestClient client;
  late TestClient json;
  late Application jsonApp;

  Application build(String serialization) =>
      Application.configure(basePath: base.path)
          .withEnv({
            'APP_ENV': 'testing',
            'APP_KEY': 'base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
            'DB_DATABASE': ':memory:',
            'SESSION_DRIVER': 'array',
            'SESSION_SERIALIZATION': serialization,
          })
          .withLogLevel(LogLevel.critical)
          .withSession()
          .withRouting(
            web: (router) {
              router.group((r) {
                Future<Object?> save(Request request) async {
                  await request.validate({'title': 'required'});
                  return {'ok': true};
                }

                r.post('/items', save);
                r.put('/items', save);
                r.get(
                  '/raw',
                  (request) => {
                    'class': switch (request.session.get<Object>('errors')) {
                      final PhpObject object => object.className,
                      final other => '${other.runtimeType}',
                    },
                  },
                );
                r.get(
                  '/shape',
                  (request) => request.session.get<Object>('errors'),
                );
                r.get('/form', (request) {
                  return {
                    'errors': request.session.errors,
                    'old': request.session.old<String>('name'),
                    'password': request.session.old<String>('password'),
                  };
                });
              }, middleware: const ['encrypt_cookies', 'session']);
            },
          )
          .create();

  setUp(() async {
    base = Directory.systemTemp.createTempSync('daravel_redirect');
    app = build('php');
    await app.boot();
    client = TestClient(app);
    jsonApp = build('json');
    await jsonApp.boot();
    json = TestClient(jsonApp);
  });

  tearDown(() async {
    await app.shutdown();
    await jsonApp.shutdown();
    base.deleteSync(recursive: true);
  });

  const browser = {'accept': 'text/html'};
  const inertia = {
    'accept': 'text/html, application/xhtml+xml',
    'x-requested-with': 'XMLHttpRequest',
    'x-inertia': 'true',
  };
  const form = {'name': 'Ana', 'password': 'secret'};

  test('a browser goes back, with errors and old input flashed', () async {
    final failed = await client.post(
      '/items',
      form: form,
      headers: {...browser, 'referer': 'http://localhost/form'},
    );
    expect(failed.status, 302);
    expect(failed.headers.first('location'), 'http://localhost/form');
    final cookie = failed.headers.all('set-cookie').first.split(';').first;
    final next = await client.get('/form', headers: {'cookie': cookie});
    expect(next.jsonMap['errors'], {
      'title': ['The title field is required.'],
    });
    expect(next.jsonMap['old'], 'Ana');
    expect(next.jsonMap['password'], isNull, reason: 'never flashed');
  });

  test('a PHP session holds a ViewErrorBag, not an array', () async {
    final failed = await client.post('/items', form: form, headers: browser);
    final cookie = failed.headers.all('set-cookie').first.split(';').first;
    final raw = await client.get('/raw', headers: {'cookie': cookie});
    expect(raw.jsonMap['class'], r'Illuminate\Support\ViewErrorBag');
  });

  test('a JSON session holds what Laravel 13 reads back', () async {
    final failed = await json.post('/items', form: form, headers: browser);
    final cookie = failed.headers.all('set-cookie').first.split(';').first;
    final raw = await json.get('/shape', headers: {'cookie': cookie});
    expect(raw.jsonMap['default'], {
      'format': ':message',
      'messages': {
        'title': ['The title field is required.'],
      },
    });
  });

  test('a JSON session reads its own errors back', () async {
    final failed = await json.post('/items', form: form, headers: browser);
    final cookie = failed.headers.all('set-cookie').first.split(';').first;
    final next = await json.get('/form', headers: {'cookie': cookie});
    expect(next.jsonMap['errors'], {
      'title': ['The title field is required.'],
    });
  });

  test('a foreign Referer is not followed', () async {
    final failed = await client.post(
      '/items',
      form: form,
      headers: {...browser, 'referer': 'https://evil.example/x'},
    );
    expect(failed.headers.first('location'), '/');
  });

  test('Inertia gets 303 after PUT, 302 after POST', () async {
    final put = await client.post(
      '/items',
      form: {...form, '_method': 'PUT'},
      headers: inertia,
    );
    expect(put.status, 303);
    final post = await client.post('/items', form: form, headers: inertia);
    expect(post.status, 302);
  });

  test('API clients keep the 422 JSON', () async {
    for (final headers in [
      const {'accept': 'application/json'},
      const {'x-requested-with': 'XMLHttpRequest'},
    ]) {
      final failed = await client.post('/items', form: form, headers: headers);
      expect(failed.status, 422, reason: '$headers');
      expect(failed.jsonMap['errors'], contains('title'));
    }
  });
}
