import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `Mw.*` (W9.6): each token is exactly the alias string, so it resolves to
/// the same middleware and can be mixed with strings.
void main() {
  test('each token is the alias string it stands for', () {
    final cases = <MiddlewareToken, String>{
      Mw.auth(): 'auth',
      Mw.auth(['token', 'jwt']): 'auth:token,jwt',
      Mw.can('update'): 'can:update',
      Mw.can('update', ['post', 'comment']): 'can:update,post,comment',
      Mw.throttle('login'): 'throttle:login',
      Mw.throttleLimit(maxAttempts: 60): 'throttle:60,1',
      Mw.throttleLimit(maxAttempts: 5, decayMinutes: 0.5): 'throttle:5,0.5',
      Mw.cacheHeaders(public: true, maxAge: 3600, etag: true):
          'cache.headers:public;max_age=3600;etag',
      // No options: the bare alias, not 'cache.headers:'.
      Mw.cacheHeaders(): 'cache.headers',
      Mw.feature(['beta', 'new-checkout']): 'feature:beta,new-checkout',
      Mw.signed: 'signed',
    };
    for (final MapEntry(key: token, value: string) in cases.entries) {
      expect(token, string);
      expect(token.value, string);
    }
  });

  test('a token resolves to the middleware its string resolves to', () {
    final signer = UrlSigner(List<int>.filled(32, 7));
    final registry = MiddlewareRegistry()
      ..aliasFactory('auth', AuthenticateMiddleware.new)
      ..alias('signed', ValidateSignatureMiddleware(signer))
      ..aliasFactory('can', AuthorizeMiddleware.fromParams)
      ..aliasFactory('cache.headers', CacheHeadersMiddleware.fromParams)
      ..aliasFactory('throttle', ThrottleMiddleware.fromParams)
      ..aliasFactory('feature', EnsureFeaturesAreActive.new);
    final can = registry.resolve(Mw.can('update', ['post'])).single;
    expect(can, isA<AuthorizeMiddleware>());
    expect((can as AuthorizeMiddleware).ability, 'update');
    expect(can.params, ['post']);
    final named = registry.resolve(Mw.throttle('login')).single;
    expect((named as ThrottleMiddleware).limiterName, 'login');
    final limit = registry
        .resolve(Mw.throttleLimit(maxAttempts: 5, decayMinutes: 0.5))
        .single;
    expect((limit as ThrottleMiddleware).maxAttempts, 5);
    expect(limit.decay, const Duration(seconds: 30));
    final cache = registry
        .resolve(
          Mw.cacheHeaders(public: true, maxAge: 60, lastModified: '1700000000'),
        )
        .single;
    expect((cache as CacheHeadersMiddleware).options, {
      'public': null,
      'max_age': '60',
      'last_modified': '1700000000',
    });
    final feature = registry.resolve(Mw.feature(['a', 'b'])).single;
    expect((feature as EnsureFeaturesAreActive).features, ['a', 'b']);
    final auth = registry.resolve(Mw.auth()).single;
    expect((auth as AuthenticateMiddleware).guards, isEmpty);
    final guarded = registry.resolve(Mw.auth(['token', 'jwt'])).single;
    expect((guarded as AuthenticateMiddleware).guards, ['token', 'jwt']);
    final signed = registry.resolve(Mw.signed).single;
    expect((signed as ValidateSignatureMiddleware).signer, same(signer));
    // No options and the string with an empty list parse alike.
    final bare = registry.resolve(Mw.cacheHeaders()).single;
    final colon = registry.resolve('cache.headers:').single;
    expect((bare as CacheHeadersMiddleware).options, isEmpty);
    expect((colon as CacheHeadersMiddleware).options, isEmpty);
  });

  test('tokens and strings mix in a route\'s middleware', () async {
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withRateLimits(
          (limiter) => limiter.define('mixed', (_) => Limit.perMinute(1)),
        )
        .withRouting(
          api: (r) {
            r.get('/limited', (_) async => {'ok': true}).middleware([
              Mw.throttleLimit(maxAttempts: 1),
              Mw.cacheHeaders(public: true, maxAge: 60),
            ]);
            // A string and a token in one list (throttle by a named
            // limiter: an unnamed limit keys on the client, not the route,
            // as Laravel's, and would share /limited's counter).
            r.get('/mixed', (_) async => {'ok': true}).middleware([
              'throttle:mixed',
              Mw.cacheHeaders(noStore: true),
            ]);
          },
        )
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    Future<Response> get(String path) =>
        app.handle(Request.fake(path: '/api$path'));
    final first = await get('/limited');
    expect(first.status, 200);
    expect(first.headers['cache-control'], 'max-age=60, public');
    expect((await get('/limited')).status, 429);
    final mixed = await get('/mixed');
    expect(mixed.status, 200);
    expect(mixed.headers['cache-control'], contains('no-store'));
    expect((await get('/mixed')).status, 429);
  });
}
