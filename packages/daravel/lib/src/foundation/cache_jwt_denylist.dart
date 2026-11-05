part of 'application.dart';

/// Revoked JWT ids in a [CacheStore], so a logout holds on every worker
/// isolate (a coordinator store) or every machine (`database`, Redis).
///
/// The default denylist of `auth.jwt(...)`: the default cache store
/// (`CACHE_STORE`), or, when that one is in memory (`memory`, `process`),
/// the coordinator's `jwtDenylist` store: a token revoked on one isolate
/// must be refused on all of them, and the ids must not share an LRU with
/// application keys that could evict them (#169). A store that fails makes
/// the guard fail, never admit.
///
/// It lives in the composition root because it joins the auth and cache
/// modules, which may not import each other.
final class CacheJwtDenylist implements JwtDenylist {
  /// [store] is resolved on first use (the cache is built after auth at
  /// boot).
  CacheJwtDenylist(this._store, {this.prefix = 'jwt_denylist:'});

  final CacheStore Function() _store;

  /// The key prefix of revoked token ids.
  final String prefix;
  CacheStore? _resolved;

  /// The cache store holding them.
  CacheStore get store => _resolved ??= _store();

  @override
  Future<void> add(String jti, DateTime expiresAt) async {
    final left = expiresAt.difference(Clock.now().toUtc());
    if (left > Duration.zero) {
      await store.put('$prefix$jti', true, ttl: left);
    }
  }

  @override
  Future<bool> contains(String jti) async =>
      await store.get('$prefix$jti') != null;
}
