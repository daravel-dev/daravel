/// Middleware written with the compiler's help: `Mw.throttle('login')`
/// instead of `'throttle:login'`, so `Mw.` lists every alias and its
/// parameters, and a misspelled alias does not compile (wave 9, W9.6).
library;

/// A middleware alias with its parameters, as the alias string the
/// middleware registry resolves (`'throttle:login'`). It is that string
/// (`implements String`), so it goes wherever middleware names go:
/// `.middleware([...])`, `group(middleware: [...])`, `middleware.group`.
extension type const MiddlewareToken(String value) implements String {}

/// The middleware aliases Daravel registers, as [MiddlewareToken]s. Each
/// returns the string its alias parses (`Mw.can('update', ['post'])` is
/// `'can:update,post'`), so both forms can be mixed in one list. A package
/// that registers aliases offers its own tokens (`SessionMw`, ...).
abstract final class Mw {
  /// `auth`, or `auth:token,jwt`: an authenticated user on the first of
  /// [guards] that has one (the default guard when empty).
  static MiddlewareToken auth([List<String> guards = const []]) =>
      MiddlewareToken(guards.isEmpty ? 'auth' : 'auth:${guards.join(',')}');

  /// `can:update,post`: 403 unless the user may perform [ability], with the
  /// route parameters [routeParams] (bound models or raw values) as its
  /// arguments.
  static MiddlewareToken can(
    String ability, [
    List<String> routeParams = const [],
  ]) => MiddlewareToken('can:${[ability, ...routeParams].join(',')}');

  /// `throttle:login`: the rate limiter registered as [limiter].
  static MiddlewareToken throttle(String limiter) =>
      MiddlewareToken('throttle:$limiter');

  /// `throttle:60,1`: [maxAttempts] per [decayMinutes] (fractions allowed),
  /// without a named limiter. As in Laravel, the count is kept per client
  /// (user or IP), not per route: two routes with an unnamed limit share
  /// it. Give a route its own count with a named limiter ([throttle]).
  static MiddlewareToken throttleLimit({
    required int maxAttempts,
    num decayMinutes = 1,
  }) => MiddlewareToken('throttle:$maxAttempts,$decayMinutes');

  /// `cache.headers:public;max_age=3600;etag`: the response's
  /// `Cache-Control`, `ETag` and `Last-Modified`, as Laravel's
  /// `cache.headers` (the directives Symfony writes).
  static MiddlewareToken cacheHeaders({
    bool public = false,
    bool private = false,
    int? maxAge,
    int? sMaxage,
    bool mustRevalidate = false,
    bool noCache = false,
    bool noStore = false,
    bool noTransform = false,
    bool proxyRevalidate = false,
    bool immutable = false,
    int? staleWhileRevalidate,
    int? staleIfError,
    bool etag = false,
    String? lastModified,
  }) {
    final options = [
      if (public) 'public',
      if (private) 'private',
      if (maxAge != null) 'max_age=$maxAge',
      if (sMaxage != null) 's_maxage=$sMaxage',
      if (mustRevalidate) 'must_revalidate',
      if (noCache) 'no_cache',
      if (noStore) 'no_store',
      if (noTransform) 'no_transform',
      if (proxyRevalidate) 'proxy_revalidate',
      if (immutable) 'immutable',
      if (staleWhileRevalidate != null)
        'stale_while_revalidate=$staleWhileRevalidate',
      if (staleIfError != null) 'stale_if_error=$staleIfError',
      if (etag) 'etag',
      if (lastModified != null) 'last_modified=$lastModified',
    ];
    return MiddlewareToken('cache.headers:${options.join(';')}');
  }

  /// `feature:beta,new-checkout`: 400 unless every one of [features] is
  /// active.
  static MiddlewareToken feature(List<String> features) =>
      MiddlewareToken('feature:${features.join(',')}');

  /// `signed`: 403 unless the URL carries a valid, unexpired signature.
  static const MiddlewareToken signed = MiddlewareToken('signed');
}
