part of 'application.dart';

/// Rate limits counted in a [CacheStore] (`CACHE_LIMITER`, Laravel's
/// `cache.limiter`): with the `database` store, every machine sharing the
/// database shares the limits (scope `cluster`).
///
/// Laravel's cache algorithm: a `<key>:timer` entry holds the end of the
/// window and `<key>` the hits, both expiring with it. An attempt over the
/// limit is taken back, so blocked requests are not counted (as the other
/// stores and Laravel's middleware, which checks before it hits).
///
/// It lives in the composition root because it joins the cache module and
/// the HTTP rate limiter, which may not import each other.
final class CacheRateLimitStore implements RateLimitStore {
  /// [store] is resolved on first use (the cache is built after the
  /// limiter at boot).
  CacheRateLimitStore(this._store, {this.prefix = 'rate_limiter:'});

  final CacheStore Function() _store;
  final String prefix;
  CacheStore? _resolved;

  CacheStore get store => _resolved ??= _store();

  @override
  StateScope get scope => store.scope;

  static int get _nowMs => Clock.now().toUtc().millisecondsSinceEpoch;

  static int _int(Object? value) => switch (value) {
    final int value => value,
    final num value => value.toInt(),
    final String value => int.tryParse(value) ?? 0,
    _ => 0,
  };

  @override
  Future<RateLimitResult> attempt(
    String key,
    int maxAttempts,
    Duration decay,
  ) async {
    final hitsKey = '$prefix$key';
    final timerKey = '$hitsKey:timer';
    await store.add(timerKey, _nowMs + decay.inMilliseconds, ttl: decay);
    final added = await store.add(hitsKey, 0, ttl: decay);
    var hits = await store.increment(hitsKey);
    if (!added && hits == 1) {
      // Either the counter expired between add and increment (increment
      // then created it without a lifetime), or another request added it
      // and has not incremented yet. Laravel resets it to 1, which loses
      // that other request's hit; giving it a lifetime keeps the count.
      final store = this.store;
      if (store is TouchableCacheStore) {
        await store.touch(hitsKey, decay);
      } else {
        await store.put(hitsKey, 1, ttl: decay);
      }
    }
    final resetAtMs = _int(await store.get(timerKey));
    final resetAt = DateTime.fromMillisecondsSinceEpoch(
      resetAtMs == 0 ? _nowMs + decay.inMilliseconds : resetAtMs,
      isUtc: true,
    );
    if (hits > maxAttempts) {
      hits = await store.decrement(hitsKey);
      return RateLimitResult(
        allowed: false,
        limit: maxAttempts,
        remaining: 0,
        resetAt: resetAt,
        retryAfter: _until(resetAt),
      );
    }
    return RateLimitResult(
      allowed: true,
      limit: maxAttempts,
      remaining: maxAttempts - hits,
      resetAt: resetAt,
    );
  }

  static Duration _until(DateTime resetAt) {
    final left = resetAt.millisecondsSinceEpoch - _nowMs;
    return Duration(milliseconds: left > 0 ? left : 0);
  }

  @override
  Future<int> attempts(String key, Duration decay) async =>
      _int(await store.get('$prefix$key'));

  @override
  Future<Duration> availableIn(
    String key,
    int maxAttempts,
    Duration decay,
  ) async {
    if (await attempts(key, decay) < maxAttempts) {
      return Duration.zero;
    }
    final resetAtMs = _int(await store.get('$prefix$key:timer'));
    return resetAtMs == 0
        ? Duration.zero
        : _until(DateTime.fromMillisecondsSinceEpoch(resetAtMs, isUtc: true));
  }

  @override
  Future<void> clear(String key) async {
    await store.forget('$prefix$key');
    await store.forget('$prefix$key:timer');
  }

  /// Not supported: the cache is shared with the application, so flushing it
  /// would drop everything; [clear] keys one by one.
  @override
  Future<void> flush() => throw UnsupportedError(
    'CacheRateLimitStore cannot flush a shared cache store; clear(key) '
    'each limit instead.',
  );
}
