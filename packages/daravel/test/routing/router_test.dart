import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class _Noop implements Middleware {
  const _Noop();

  @override
  Future<Response> handle(Request request, Next next) => next(request);
}

Router _build() {
  final router = Router();
  router.get('/', (_) => 'home').name('home');
  router.group(
    (r) {
      r.get('/users', (_) => 'index').name('users.index');
      r.post('/users', (_) => 'store').name('users.store');
      r.get('/users/{id}', (_) => 'show').name('users.show').middleware(
        <Object>['auth'],
      );
      r.group(
        (r) => r.delete('/users/{id}', (_) => 'destroy').name('users.destroy'),
        middleware: <Object>[const _Noop()],
      );
    },
    prefix: '/api',
    name: 'api.',
    middleware: <Object>[const RequestIdMiddleware()],
  );
  router.get('/files/{path*}', (_) => 'files').name('files');
  router.compile(MiddlewareRegistry()..alias('auth', const _Noop()));
  return router;
}

void main() {
  test('matches routes with group prefixes and names', () {
    final router = _build();
    expect(router.lookup('GET', '/')!.value.routeName, 'home');
    expect(
      router.lookup('GET', '/api/users')!.value.routeName,
      'api.users.index',
    );
    expect(
      router.lookup('post', '/api/users')!.value.routeName,
      'api.users.store',
    );
    final show = router.lookup('GET', '/api/users/7')!;
    expect(show.value.routeName, 'api.users.show');
    expect(show.params, <String, String>{'id': '7'});
    expect(router.lookup('GET', '/nope'), isNull);
  });

  test('HEAD falls back to GET routes', () {
    final router = _build();
    expect(
      router.lookup('HEAD', '/api/users')!.value.routeName,
      'api.users.index',
    );
  });

  test('reports allowed methods for 405 / OPTIONS handling', () {
    final router = _build();
    expect(router.allowedMethods('/api/users'), <String>[
      'GET',
      'HEAD',
      'POST',
    ]);
    expect(router.allowedMethods('/api/users/3'), <String>[
      'GET',
      'HEAD',
      'DELETE',
    ]);
    expect(router.allowedMethods('/missing'), isEmpty);
  });

  test('stacks group and route middleware in order', () {
    final router = _build();
    final show = router.lookup('GET', '/api/users/1')!.value;
    expect(show.resolvedMiddleware.length, 2);
    expect(show.resolvedMiddleware.first, isA<RequestIdMiddleware>());
    expect(show.resolvedMiddleware.last, isA<_Noop>());
    final destroy = router.lookup('DELETE', '/api/users/1')!.value;
    expect(destroy.resolvedMiddleware.length, 2);
    expect(
      router.lookup('GET', '/api/users')!.value.resolvedMiddleware.length,
      1,
    );
  });

  test('generates urls for named routes', () {
    final router = _build();
    expect(router.url('home'), '/');
    expect(
      router.url(
        'api.users.show',
        params: <String, Object?>{'id': 5},
        query: <String, Object?>{'tab': 'posts', 'x': null},
      ),
      '/api/users/5?tab=posts',
    );
    expect(
      router.url('files', params: <String, Object?>{'path': 'css/app css.css'}),
      '/files/css/app%20css.css',
    );
    expect(() => router.url('api.users.show'), throwsArgumentError);
    expect(() => router.url('unknown'), throwsArgumentError);
    expect(router.has('files'), isTrue);
  });

  test('exposes parameter names', () {
    final router = _build();
    expect(router.lookup('GET', '/api/users/1')!.value.parameterNames, <String>[
      'id',
    ]);
    expect(router.lookup('GET', '/files/a/b')!.value.parameterNames, <String>[
      'path',
    ]);
  });

  test('rejects duplicate names, unknown aliases and late registration', () {
    final router = Router()
      ..get('/a', (_) => null).name('dup')
      ..get('/b', (_) => null).name('dup');
    expect(() => router.compile(MiddlewareRegistry()), throwsStateError);

    final unknownAlias = Router()
      ..get('/a', (_) => null).middleware(<Object>['nope']);
    expect(() => unknownAlias.compile(MiddlewareRegistry()), throwsStateError);

    final compiled = _build();
    expect(() => compiled.get('/late', (_) => null), throwsStateError);
    expect(() => Router().lookup('GET', '/'), throwsStateError);
  });
}
