import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class StorePostRequest extends FormRequest {
  const StorePostRequest();

  @override
  Future<bool> authorize(Request request) async =>
      request.header('x-role') != 'guest';

  @override
  Map<String, Object> rules(Request request) => {
    'title': 'required|string|max:120',
    'body': 'nullable|string',
    'tags': 'sometimes|array|max:5',
    'tags.*': 'string|min:2',
  };
}

void main() {
  group('rulesToJsonSchema', () {
    test('types, required, nullable and bounds per type', () {
      final schema = rulesToJsonSchema({
        'email': 'required|email|max:255',
        'age': 'nullable|integer|between:18,99',
        'nickname': 'sometimes|required|string|min:3',
        'role': [
          'required',
          Rules.inList(['admin', 'editor']),
        ],
        'password': 'required|string|min:8|confirmed',
      });
      expect(schema['type'], 'object');
      final properties = schema['properties']! as Map<String, Object?>;
      expect(properties['email'], {
        'type': 'string',
        'format': 'email',
        'maxLength': 255,
      });
      expect(properties['age'], {
        'type': ['integer', 'null'],
        'minimum': 18,
        'maximum': 99,
      });
      expect(properties['nickname'], {'type': 'string', 'minLength': 3});
      expect((properties['role']! as Map)['enum'], ['admin', 'editor']);
      expect(properties['password'], {'type': 'string', 'minLength': 8});
      expect(
        rulesToJsonSchema({
          'secret': [Rules.password(min: 12)],
        })['properties'],
        {
          'secret': {'type': 'string', 'format': 'password', 'minLength': 12},
        },
      );
      expect(
        properties['password_confirmation'],
        containsPair('type', 'string'),
      );
      expect(schema['required'], [
        'email',
        'role',
        'password',
        'password_confirmation',
      ]);
    });

    test('array is an array or an object unless nested rules say which', () {
      final properties =
          rulesToJsonSchema({
                'stem': 'required|array',
                'meta': 'nullable|array',
                'ids': 'array',
                'ids.*': 'integer',
                'address': 'array',
                'address.city': 'string',
                'tags': 'list|max:3',
              })['properties']!
              as Map<String, Object?>;
      Object? type(String key) => (properties[key]! as Map)['type'];
      expect(type('stem'), ['array', 'object']);
      expect(type('meta'), ['array', 'object', 'null']);
      expect(type('ids'), 'array');
      expect(type('address'), 'object');
      expect(type('tags'), 'array');
      expect((properties['tags']! as Map)['maxItems'], 3);
    });

    test('dotted keys nest objects and * becomes array items', () {
      final schema = rulesToJsonSchema({
        'address.city': 'required|string',
        'items': 'required|array|min:1',
        'items.*.id': 'required|integer',
      });
      final properties = schema['properties']! as Map<String, Object?>;
      final address = properties['address']! as Map<String, Object?>;
      expect(address['type'], 'object');
      expect(address['required'], ['city']);
      final items = properties['items']! as Map<String, Object?>;
      expect(items['type'], 'array');
      expect(items['minItems'], 1);
      final item = items['items']! as Map<String, Object?>;
      expect(item['required'], ['id']);
      expect((item['properties']! as Map)['id'], {'type': 'integer'});
    });
  });

  group('declared validation on routes', () {
    late Application app;

    setUp(() async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withRouting(
            apiPrefix: '/api',
            api: (r) {
              r
                  .post('/posts', (req) => req.validated().toMap())
                  .validates(const StorePostRequest())
                  .returns(const {'type': 'object'}, name: 'Post')
                  .action('PostController@store');
              r.get('/search', (req) => req.validated().toMap()).rules(const {
                'q': 'required|string|min:2',
              });
              r.get('/plain', (req) => req.validated().toMap());
            },
          )
          .create();
      await app.boot();
    });
    tearDown(() => app.shutdown());

    Future<Response> send(Request request) => app.handle(request);

    test('a valid request reaches the handler with validated data', () async {
      final res = await send(
        Request.fake(
          method: 'POST',
          path: '/api/posts',
          json: const {'title': 'Hello', 'extra': 'dropped'},
        ),
      );
      expect(res.status, 200);
      expect(await res.bodyText(), '{"title":"Hello"}');
    });

    test('invalid input answers 422 before the handler', () async {
      final res = await send(
        Request.fake(method: 'POST', path: '/api/posts', json: const {}),
      );
      expect(res.status, 422);
      expect(await res.bodyText(), contains('The title field is required.'));
    });

    test('authorize() false answers 403', () async {
      final res = await send(
        Request.fake(
          method: 'POST',
          path: '/api/posts',
          json: const {'title': 'x'},
          headers: const {'x-role': 'guest'},
        ),
      );
      expect(res.status, 403);
    });

    test('inline rules validate query input', () async {
      expect(
        (await send(Request.fake(path: '/api/search', query: const {'q': 'a'})))
            .status,
        422,
      );
      final ok = await send(
        Request.fake(path: '/api/search', query: const {'q': 'dart'}),
      );
      expect(await ok.bodyText(), '{"q":"dart"}');
    });

    test('validated() without declared validation is a clear error', () async {
      final res = await send(Request.fake(path: '/api/plain'));
      expect(res.status, 500);
    });

    test('metadata is readable for documentation tools', () {
      final post = app.router.routes.firstWhere((r) => r.path == '/api/posts');
      expect(post.formRequest, isA<StorePostRequest>());
      expect(post.documentedRules()!.keys, contains('title'));
      expect(post.declaredResponse!.name, 'Post');
      expect(post.actionName, 'PostController@store');
    });
  });

  group('file responses', () {
    const xlsx =
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

    Map<String, Object?> okResponse(Router router, String path) {
      router.compile(MiddlewareRegistry());
      final paths =
          buildOpenApi(router.routes)['paths']! as Map<String, Object?>;
      final get = (paths[path]! as Map)['get'] as Map;
      return (get['responses'] as Map)['200'] as Map<String, Object?>;
    }

    test('returnsFile documents a binary body and Content-Disposition', () {
      final router = Router();
      final route = router
          .get('/export', (_) => null)
          .returnsFile(contentType: xlsx);
      expect(route.declaredResponse!.isFile, isTrue);
      final ok = okResponse(router, '/export');
      expect(ok['content'], {
        xlsx: {'schema': RouteResponse.binarySchema},
      });
      expect((ok['headers']! as Map).keys, ['Content-Disposition']);
    });

    test('a raw binary schema is a file; JSON shapes are not', () {
      final router = Router()
        ..get(
          '/template',
          (_) => null,
        ).returns(RouteResponse.binarySchema, shape: .raw);
      expect(router.routes.single.declaredResponse!.isFile, isTrue);
      expect(okResponse(router, '/template')['content'], {
        'application/octet-stream': {'schema': RouteResponse.binarySchema},
      });
      expect(const RouteResponse({'type': 'object'}).isFile, isFalse);
      expect(
        const RouteResponse({
          'type': 'object',
        }, contentType: 'application/vnd.api+json').isFile,
        isFalse,
      );
      expect(
        const RouteResponse({
          'type': 'string',
        }, contentType: 'text/csv; charset=utf-8').isFile,
        isTrue,
      );
    });
  });
}
