@Tags(['conformance'])
library;

import 'package:daravel/daravel.dart';
import 'package:daravel_test/conformance.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import 'conformance_app.dart';

/// Error bodies, status codes, headers and JSON dates locked to Laravel 13
/// (`Foundation/Exceptions/Handler.php`, routing, throttle, validation).
void main() {
  late Application app;
  late TestClient client;

  setUp(() async => (app, client) = await bootConformanceApp());
  tearDown(() => app.shutdown());

  group('error bodies', () {
    test('404 for an unknown route', () async {
      final res = await client.get('/api/nope/deeper');
      res.assertNotFound();
      expect(
        res.json,
        isLaravelErrorBody(LaravelContract.routeNotFound('api/nope/deeper')),
      );
    });

    test('404 route label for the root is "/"', () async {
      final res = await client.get('/');
      res.assertNotFound();
      expect(res.json, isLaravelErrorBody(LaravelContract.routeNotFound('/')));
    });

    test('405 lists the supported methods and sets Allow', () async {
      final res = await client.delete('/api/echo');
      res.assertMethodNotAllowed().assertHeader('allow', 'POST');
      expect(
        res.json,
        isLaravelErrorBody(
          LaravelContract.methodNotAllowed('DELETE', 'api/echo', ['POST']),
        ),
      );
    });

    test('404 from findOrFail names the model class and id', () async {
      final res = await client.get('/api/users/42');
      res.assertNotFound();
      expect(
        res.json,
        isLaravelErrorBody(
          LaravelContract.modelNotFound(LaravelContract.morphClass('User'), [
            42,
          ]),
        ),
      );
    });

    test('404 from firstOrFail ends with a period', () async {
      final res = await client.get('/api/users-first');
      expect(
        res.json,
        isLaravelErrorBody(
          LaravelContract.modelNotFound(LaravelContract.morphClass('User')),
        ),
      );
    });

    test('abort(code) without a message renders an empty message', () async {
      for (final code in [400, 403, 404, 409, 503]) {
        final res = await client.get('/api/abort/$code');
        res.assertStatus(code);
        expect(res.json, isLaravelErrorBody(''), reason: 'abort($code)');
      }
      (await client.get('/api/teapot')).assertStatus(418);
    });

    test('401 for a guarded route without credentials', () async {
      final res = await client.get('/api/me');
      res.assertUnauthorized();
      expect(res.json, isLaravelErrorBody(LaravelContract.unauthenticated));
    });

    test('403 for a denied gate', () async {
      final res = await client.get('/api/forbidden');
      res.assertForbidden();
      expect(res.json, isLaravelErrorBody(LaravelContract.unauthorized));
    });

    test('500 hides the exception when APP_DEBUG=false', () async {
      final res = await client.get('/api/boom');
      res.assertServerError();
      expect(res.json, isLaravelErrorBody(LaravelContract.serverError));
      expect(res.body, isNot(contains('secret detail')));
    });

    test('413 when the body exceeds the limit', () async {
      final res = await client.post(
        '/api/echo',
        json: <String, Object?>{'blob': 'x' * 1000},
      );
      res.assertStatus(413);
      expect(res.json, isLaravelErrorBody(LaravelContract.postTooLarge));
    });

    test('429 with Laravel throttle headers', () async {
      final ok = await client.get('/api/throttled');
      ok
          .assertOk()
          .assertHeader('x-ratelimit-limit', '1')
          .assertHeader('x-ratelimit-remaining', '0');
      final limited = await client.get('/api/throttled');
      limited.assertStatus(429);
      expect(limited.json, isLaravelErrorBody(LaravelContract.tooManyAttempts));
      for (final header in LaravelContract.throttleHeaders) {
        limited.assertHeader(header);
      }
      limited.assertHeader('x-ratelimit-remaining', '0');
      final retryAfter = int.parse(limited.headers.first('retry-after')!);
      expect(retryAfter, inInclusiveRange(1, 60));
    });
  });

  group('validation (422)', () {
    test('body is {message, errors} with the Laravel summary', () async {
      final res = await client.post(
        '/api/validate',
        json: <String, Object?>{'name': 'toolong', 'password': 'short'},
      );
      res.assertUnprocessable();
      expect(
        res.json,
        isLaravelValidationError({
          'name': ['The name field must not be greater than 5 characters.'],
          'email': ['The email field is required.'],
          'password': [
            'The password field must be at least 8 characters.',
            'The password field confirmation does not match.',
          ],
        }),
      );
      expect(
        res.jsonMap['message'],
        'The name field must not be greater than 5 characters. '
        '(and 3 more errors)',
      );
    });

    test('a single error has no "(and N more)" suffix', () async {
      final res = await client.post(
        '/api/validate',
        json: <String, Object?>{
          'name': 'Ana',
          'email': 'ana@example.com',
          'password': 'secret123',
        },
      );
      expect(
        res.json,
        isLaravelValidationError({
          'password': ['The password field confirmation does not match.'],
        }),
      );
      expect(
        res.jsonMap['message'],
        'The password field confirmation does not match.',
      );
    });

    test('nullable stops on null, sometimes skips absent keys', () async {
      final res = await client.post(
        '/api/validate',
        json: <String, Object?>{
          'name': 'Ana',
          'email': 'ana@example.com',
          'password': 'secret123',
          'password_confirmation': 'secret123',
          'age': null,
        },
      );
      res.assertOk();
      expect(res.jsonMap.containsKey('nickname'), isFalse);
      expect(res.jsonMap['age'], isNull);
    });

    test('sometimes validates a present key', () async {
      final res = await client.post(
        '/api/validate',
        json: <String, Object?>{
          'name': 'Ana',
          'email': 'ana@example.com',
          'password': 'secret123',
          'password_confirmation': 'secret123',
          'nickname': '',
        },
      );
      expect(
        res.json,
        isLaravelValidationError({
          'nickname': ['The nickname field is required.'],
        }),
      );
    });

    test('default English messages equal Laravel 13 lang/en/validation.php', () {
      final daravel = ValidationMessages.translations['en']!;
      final mismatches = <String>[
        for (final entry in daravel.entries)
          if (laravelValidationMessages.containsKey(entry.key) &&
              laravelValidationMessages[entry.key] != entry.value)
            '${entry.key}: "${entry.value}" != "${laravelValidationMessages[entry.key]}"',
      ];
      expect(mismatches, isEmpty);
      // Every Daravel key is either Laravel's or a documented extension.
      final extensions = daravel.keys
          .where((k) => !laravelValidationMessages.containsKey(k))
          .toSet();
      expect(extensions, <String>{'map', 'custom'});
    });
  });

  group('JSON dates', () {
    test('DateTime serializes like Carbon::toJSON (microseconds, Z)', () async {
      final res = await client.get('/api/date');
      expect(res.jsonMap['at'], '2026-01-02T03:04:05.006007Z');
      expect(res.jsonMap['at'], matches(LaravelContract.jsonDate));
    });

    test('model timestamps use the same format', () async {
      final user = await app.run(
        () => User.definition.query().create({
          'name': 'Ana',
          'email': 'ana@example.com',
          'password': 'x',
        }),
      );
      final json = user.toJson();
      expect(json['created_at'], matches(LaravelContract.jsonDate));
      expect(json.containsKey('password'), isFalse);
    });
  });

  group('resource routes', () {
    test('apiResource names, URIs and the singular parameter', () {
      final routes = app.router.routes;
      for (final (method, uri, name) in LaravelContract.apiResource(
        'photos',
        'photo',
      )) {
        final match = routes.where(
          (r) =>
              r.methods.contains(method) &&
              r.path == '/api/$uri' &&
              r.routeName == name,
        );
        expect(match, isNotEmpty, reason: '$method /api/$uri ($name)');
      }
    });

    test('the bound parameter reaches the controller', () async {
      (await client.get('/api/photos/7')).assertOk();
      expect((await client.get('/api/photos/7')).body, contains('show 7'));
    });
  });
}
