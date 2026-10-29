@Tags(['conformance'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// `COMPAT_LARAVEL_VERSION`: the 422, 404 and 405 bodies of each Laravel
/// major, checked against its source (laravel/framework
/// `Validation/ValidationException::summarize`,
/// `Routing/AbstractRouteCollection`, and the `lang/en/validation.php` of
/// laravel/laravel 8.x and 9.x and laravel/framework 10.x to 13.x).
void main() {
  Future<TestClient> boot(String? version) async {
    final base = Directory.systemTemp.createTempSync('daravel_compat');
    final app = Application.configure(basePath: base.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'COMPAT_LARAVEL_VERSION': ?version,
        })
        .withRouting(
          api: (r) => r.post(
            '/users',
            (req) async => (await req.validate({
              'name': 'required|string',
              'email': 'required|email',
            })).toMap(),
          ),
        )
        .create();
    await app.boot();
    addTearDown(() async {
      await app.shutdown();
      base.deleteSync(recursive: true);
    });
    return TestClient(app);
  }

  for (final version in ['10', '11', '12', '13', null]) {
    test('Laravel ${version ?? '12 (default)'} formats', () async {
      final client = await boot(version);
      final invalid = await client.post(
        '/api/users',
        json: {'name': 3, 'email': 'x'},
      );
      expect(invalid.jsonMap, {
        'message': 'The name field must be a string. (and 1 more error)',
        'errors': {
          'name': ['The name field must be a string.'],
          'email': ['The email field must be a valid email address.'],
        },
      });
      final missing = await client.get('/api/nope');
      expect(missing.jsonMap, {
        'message': 'The route api/nope could not be found.',
      });
      final wrongVerb = await client.get('/api/users');
      expect(wrongVerb.jsonMap, {
        'message':
            'The GET method is not supported for route api/users. '
            'Supported methods: POST.',
      });
    });
  }

  test('Laravel 9: older validation messages, modern bodies', () async {
    final client = await boot('9');
    final invalid = await client.post(
      '/api/users',
      json: {'name': 3, 'email': 'x'},
    );
    expect(invalid.jsonMap, {
      'message': 'The name must be a string. (and 1 more error)',
      'errors': {
        'name': ['The name must be a string.'],
        'email': ['The email must be a valid email address.'],
      },
    });
    final missing = await client.get('/api/nope');
    expect(
      missing.jsonMap['message'],
      'The route api/nope could not be found.',
    );
  });

  test('Laravel 8: the given data was invalid, bare 404 and 405', () async {
    final client = await boot('8.x');
    final invalid = await client.post('/api/users', json: {'email': 'x'});
    expect(invalid.status, 422);
    expect(invalid.jsonMap, {
      'message': 'The given data was invalid.',
      'errors': {
        'name': ['The name field is required.'],
        'email': ['The email must be a valid email address.'],
      },
    });
    final missing = await client.get('/api/nope');
    expect(missing.status, 404);
    expect(missing.jsonMap, {'message': ''});
    final wrongVerb = await client.get('/api/users');
    expect(wrongVerb.status, 405);
    expect(wrongVerb.jsonMap, {
      'message':
          'The GET method is not supported for this route. '
          'Supported methods: POST.',
    });
  });

  test('an unsupported version fails at boot', () async {
    expect(() => boot('7'), throwsA(isA<ConfigException>()));
    expect(AppConfig.parseLaravelCompat('13.30.1'), 13);
  });

  test('outside an application the default (12) applies', () {
    expect(
      ValidationException.summarize({
        'a': ['x'],
        'b': ['y'],
      }),
      'x (and 1 more error)',
    );
    expect(
      ValidationException.summarize({
        'a': ['x'],
      }, laravelCompat: 8),
      'The given data was invalid.',
    );
  });
}
