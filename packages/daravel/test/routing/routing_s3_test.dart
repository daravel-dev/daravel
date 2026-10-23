import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class _Posts implements ResourceController {
  @override
  Object? index(Request r) => 'index';
  @override
  Object? store(Request r) => 'store';
  @override
  Object? show(Request r) => 'show:${r.param<String>('post')}';
  @override
  Object? update(Request r) => 'update';
  @override
  Object? destroy(Request r) => 'destroy';
}

final class _Comments implements WebResourceController {
  @override
  Object? index(Request r) => 'index:${r.param<String>('post')}';
  @override
  Object? create(Request r) => 'create';
  @override
  Object? store(Request r) => 'store';
  @override
  Object? show(Request r) =>
      'show:${r.param<String>('post')}/${r.param<String>('comment')}';
  @override
  Object? edit(Request r) => 'edit';
  @override
  Object? update(Request r) => 'update';
  @override
  Object? destroy(Request r) => 'destroy';
}

final class User {
  const User(this.id);
  final int id;
}

void main() {
  group('RadixTree with constraints', () {
    test(
      'first accepted value wins and backtracks across parameter branches',
      () {
        final tree = RadixTree<String>()
          ..insert('/posts/{id}', 'numeric')
          ..insert('/posts/{slug}', 'slug')
          ..insert('/posts/{id}/edit', 'edit');
        bool accept(String value, Map<String, String> params) =>
            value != 'numeric' || RegExp(r'^\d+$').hasMatch(params['id']!);

        expect(tree.lookup('/posts/42', accept: accept)!.value, 'numeric');
        final slug = tree.lookup('/posts/hello', accept: accept)!;
        expect(slug.value, 'slug');
        expect(slug.params, {'slug': 'hello'});
        expect(tree.lookup('/posts/7/edit', accept: accept)!.params, {
          'id': '7',
        });
      },
    );
  });

  group('Router S3', () {
    test('where constraints, global patterns and optional parameters', () {
      final router = Router()
        ..pattern('id', r'\d+')
        ..get('/users/{id}', (_) => 'user').name('users.show')
        ..get(
          '/users/{name}',
          (_) => 'by-name',
        ).name('users.byName').whereAlpha('name')
        ..get('/posts/{year}/{month?}', (_) => 'archive')
            .name('archive')
            .whereNumber('year')
            .whereIn('month', const ['01', '02'])
            .defaults({'month': '01'})
        ..get('/files/{uuid}', (_) => 'file').whereUuid('uuid')
        ..compile(MiddlewareRegistry());

      expect(router.lookup('GET', '/users/42')!.value.routeName, 'users.show');
      expect(
        router.lookup('GET', '/users/ana')!.value.routeName,
        'users.byName',
      );
      expect(router.lookup('GET', '/users/ana1'), isNull);
      expect(router.lookup('GET', '/posts/2026')!.params, {'year': '2026'});
      expect(router.lookup('GET', '/posts/2026/02')!.params, {
        'year': '2026',
        'month': '02',
      });
      expect(router.lookup('GET', '/posts/2026/13'), isNull);
      expect(router.lookup('GET', '/posts/abcd'), isNull);
      expect(
        router.lookup('GET', '/files/123e4567-e89b-12d3-a456-426614174000'),
        isNotNull,
      );
      expect(router.lookup('GET', '/files/nope'), isNull);
      expect(router.allowedMethods('/users/ana1'), isEmpty);

      expect(router.url('archive', params: {'year': 2026}), '/posts/2026/01');
      expect(
        router.url('archive', params: {'year': 2026, 'month': '02'}),
        '/posts/2026/02',
      );
      expect(() => Router.expandOptional('/a/{b?}/c'), throwsArgumentError);
      expect(Router.expandOptional('/a/{b?}/{c?}'), [
        '/a/{b}/{c}',
        '/a/{b}',
        '/a',
      ]);
    });

    test('group-level constraints apply to nested routes', () {
      final router = Router()
        ..group(
          (r) => r.get('/{id}', (_) => 'x').name('x'),
          prefix: '/items',
          where: {'id': r'\d+'},
        )
        ..compile(MiddlewareRegistry());
      expect(router.lookup('GET', '/items/5'), isNotNull);
      expect(router.lookup('GET', '/items/five'), isNull);
    });

    test('apiResource and nested resource register Laravel-style routes', () {
      final router = Router()
        ..apiResource('posts', _Posts(), except: const ['destroy'])
        ..resource(
          'posts.comments',
          _Comments(),
          only: const ['index', 'show', 'edit'],
        )
        ..compile(MiddlewareRegistry());

      final names = router.routes.map((r) => r.routeName).toList();
      expect(
        names,
        containsAll([
          'posts.index',
          'posts.store',
          'posts.show',
          'posts.update',
        ]),
      );
      expect(names, isNot(contains('posts.destroy')));
      expect(
        router.lookup('PATCH', '/posts/9')!.value.routeName,
        'posts.update',
      );
      expect(router.lookup('PUT', '/posts/9')!.value.routeName, 'posts.update');
      expect(
        router.lookup('GET', '/posts/9/comments/3')!.value.routeName,
        'posts.comments.show',
      );
      expect(
        router.lookup('GET', '/posts/9/comments/3/edit')!.value.routeName,
        'posts.comments.edit',
      );
      expect(
        router.url('posts.comments.show', params: {'post': 9, 'comment': 3}),
        '/posts/9/comments/3',
      );
      expect(singularize('categories'), 'category');
      expect(singularize('addresses'), 'address');
      expect(singularize('status'), 'status');
    });

    test('redirects, fallback and absolute urls', () async {
      final router = Router()
        ..permanentRedirect('/old', '/new')
        ..get('/new', (_) => 'new').name('new')
        ..fallback((_) => 'fallback')
        ..baseUrl = 'https://example.test/'
        ..compile(MiddlewareRegistry());

      final redirect = router.lookup('GET', '/old')!.value;
      final response = HttpKernel.toResponse(
        await redirect.handler(Request.fake()),
        Request.fake(),
      );
      expect(response.status, 301);
      expect(response.headers['location'], '/new');
      expect(router.lookup('GET', '/does/not/exist')!.value.isFallback, isTrue);
      expect(router.lookup('POST', '/does/not/exist'), isNull);
      expect(
        router.url('new', absolute: true, query: {'a': 1}),
        'https://example.test/new?a=1',
      );
    });

    test('signed urls round-trip and reject tampering or expiry', () {
      final signer = UrlSigner.fromAppKey(
        'base64:${base64.encode(List<int>.filled(32, 7))}',
      );
      final router = Router()
        ..get('/download/{file}', (_) => 'ok').name('download')
        ..signer = signer
        ..baseUrl = 'http://localhost:8000'
        ..compile(MiddlewareRegistry());

      final signed = router.signedUrl(
        'download',
        params: {'file': 'report.pdf'},
        query: {'v': 2},
      );
      expect(
        signed,
        startsWith('http://localhost:8000/download/report.pdf?v=2&signature='),
      );
      expect(signer.verify(Uri.parse(signed)), isTrue);
      expect(
        signer.verify(Uri.parse(signed.replaceFirst('v=2', 'v=3'))),
        isFalse,
      );
      expect(
        signer.verify(
          Uri.parse('http://localhost:8000/download/report.pdf?v=2'),
        ),
        isFalse,
      );

      final expiring = router.signedUrl(
        'download',
        params: {'file': 'x'},
        expires: const Duration(minutes: 5),
      );
      expect(signer.verify(Uri.parse(expiring)), isTrue);
      expect(
        signer.verify(
          Uri.parse(expiring),
          now: DateTime.now().add(const Duration(minutes: 6)),
        ),
        isFalse,
      );
    });
  });

  group('kernel integration', () {
    late Application app;

    setUp(() async {
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'APP_KEY': 'base64:${base64.encode(List<int>.filled(32, 1))}',
            'APP_URL': 'http://localhost:8000',
          })
          .withRouting(
            api: (r) {
              r.bind(
                'user',
                (value, _) async =>
                    int.tryParse(value) == 7 ? const User(7) : null,
              );
              r
                  .get(
                    '/users/{user}',
                    (req) => {'id': req.binding<User>('user').id},
                  )
                  .name('users.show');
              r.get('/secret', (_) => 'top').name('secret').middleware([
                'signed',
              ]);
              r
                  .get('/archive/{year}/{month?}', (req) => req.routeParams)
                  .defaults({'month': '01'});
            },
            then: [
              (r) => r.fallback(
                (_) => Response.json({'message': 'custom 404'}, status: 404),
              ),
            ],
          )
          .create();
      await app.boot();
    });

    tearDown(() => app.shutdown());

    test('route bindings resolve or 404', () async {
      final ok = await app.handle(Request.fake(path: '/api/users/7'));
      expect(jsonDecode(await ok.bodyText()), {'id': 7});
      expect(
        (await app.handle(Request.fake(path: '/api/users/8'))).status,
        404,
      );
    });

    test('signed middleware guards routes', () async {
      final signed = app.router.signedUrl('secret', absolute: false);
      expect((await app.handle(Request.fake(path: signed))).status, 200);
      expect((await app.handle(Request.fake(path: '/api/secret'))).status, 403);
    });

    test(
      'defaults fill optional parameters and fallback answers unknown GETs',
      () async {
        final archive = await app.handle(
          Request.fake(path: '/api/archive/2026'),
        );
        expect(jsonDecode(await archive.bodyText()), {
          'month': '01',
          'year': '2026',
        });
        final missing = await app.handle(Request.fake(path: '/nope'));
        expect(missing.status, 404);
        expect(jsonDecode(await missing.bodyText()), {'message': 'custom 404'});
      },
    );
  });
}
