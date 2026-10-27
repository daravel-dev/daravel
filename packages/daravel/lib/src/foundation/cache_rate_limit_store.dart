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
///
/// A [RateCounterStore] (daravel_redis) also counts [Limit.slidingWindow]
/// and [Limit.gcra], each under a key of its own.
final class CacheRateLimitStore implements AlgorithmRateLimitStore {
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

  /// Where a [WindowCounterStore] keeps the window of [key]: a key of its
  /// own, since its value format differs from the two-key algorithm's.
  String _windowKey(String key) => '$prefix$key:window';

  @override
  Future<RateLimitResult> attempt(
    String key,
    int maxAttempts,
    Duration decay,
  ) async {
    final store = this.store;
    if (store is WindowCounterStore) {
      // One round trip (the database store's single upsert).
      final hit = await store.hitWindow(_windowKey(key), maxAttempts, decay);
      return RateLimitResult(
        allowed: hit.allowed,
        limit: maxAttempts,
        remaining: hit.allowed ? maxAttempts - hit.hits : 0,
        resetAt: hit.resetAt,
        retryAfter: hit.allowed ? null : _until(hit.resetAt),
      );
    }
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

  @override
  bool supports(RateLimitAlgorithm algorithm) =>
      algorithm == RateLimitAlgorithm.fixedWindow || store is RateCounterStore;

  @override
  Future<RateLimitResult> attemptWith(
    RateLimitAlgorithm algorithm,
    String key,
    int maxAttempts,
    Duration decay,
  ) async {
    final store = this.store;
    if (store is! RateCounterStore ||
        algorithm == RateLimitAlgorithm.fixedWindow) {
      return attempt(key, maxAttempts, decay);
    }
    final hit = algorithm == RateLimitAlgorithm.gcra
        ? await store.hitGcra('$prefix$key:gcra', maxAttempts, decay)
        : await store.hitSlidingWindow(
            '$prefix$key:sliding',
            maxAttempts,
            decay,
          );
    return RateLimitResult(
      allowed: hit.allowed,
      limit: maxAttempts,
      remaining: hit.remaining,
      resetAt: DateTime.fromMillisecondsSinceEpoch(
        _nowMs + hit.resetIn.inMilliseconds,
        isUtc: true,
      ),
      retryAfter: hit.allowed ? null : hit.retryAfter,
    );
  }

  static Duration _until(DateTime resetAt) {
    final left = resetAt.millisecondsSinceEpoch - _nowMs;
    return Duration(milliseconds: left > 0 ? left : 0);
  }

  @override
  Future<int> attempts(String key, Duration decay) async {
    final store = this.store;
    if (store is WindowCounterStore) {
      return (await store.currentWindow(_windowKey(key)))?.hits ?? 0;
    }
    return _int(await store.get('$prefix$key'));
  }

  @override
  Future<Duration> availableIn(
    String key,
    int maxAttempts,
    Duration decay,
  ) async {
    final store = this.store;
    if (store is WindowCounterStore) {
      final window = await store.currentWindow(_windowKey(key));
      return window == null || window.hits < maxAttempts
          ? Duration.zero
          : _until(window.resetAt);
    }
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
    await store.forget(_windowKey(key));
    await store.forget('$prefix$key:sliding');
    await store.forget('$prefix$key:gcra');
  }

  /// Not supported: the cache is shared with the application, so flushing it
  /// would drop everything; [clear] keys one by one.
  @override
  Future<void> flush() => throw UnsupportedError(
    'CacheRateLimitStore cannot flush a shared cache store; clear(key) '
    'each limit instead.',
  );
}
