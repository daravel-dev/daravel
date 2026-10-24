import 'dart:async';

import '../foundation/clock.dart';

import '../server/coordinator.dart';
import 'http_exceptions.dart';
import 'middleware.dart';
import 'request.dart';
import 'response.dart';

/// Builds the 429 response for a limit (`Limit.response`).
typedef ThrottleResponseBuilder = Response Function(
  Request request,
  Map<String, String> headers,
);

/// A rate limit (Laravel `Illuminate\Cache\RateLimiting\Limit`).
final class Limit {
  const Limit({
    required this.maxAttempts,
    required this.decay,
    this.key,
    this.responseBuilder,
  });

  factory Limit.perSecond(int maxAttempts, [int seconds = 1]) => Limit(
    maxAttempts: maxAttempts,
    decay: Duration(seconds: seconds),
  );

  factory Limit.perMinute(int maxAttempts, [int minutes = 1]) => Limit(
    maxAttempts: maxAttempts,
    decay: Duration(minutes: minutes),
  );

  factory Limit.perHour(int maxAttempts, [int hours = 1]) => Limit(
    maxAttempts: maxAttempts,
    decay: Duration(hours: hours),
  );

  factory Limit.perDay(int maxAttempts, [int days = 1]) => Limit(
    maxAttempts: maxAttempts,
    decay: Duration(days: days),
  );

  /// No limit at all.
  const Limit.none()
    : maxAttempts = -1,
      decay = Duration.zero,
      key = null,
      responseBuilder = null;

  final int maxAttempts;
  final Duration decay;

  /// Segment key (user id, email+ip, …); defaults to the request signature.
  final Object? key;
  final ThrottleResponseBuilder? responseBuilder;

  bool get isUnlimited => maxAttempts < 0;

  Limit by(Object key) => Limit(
    maxAttempts: maxAttempts,
    decay: decay,
    key: key,
    responseBuilder: responseBuilder,
  );

  Limit response(ThrottleResponseBuilder builder) => Limit(
    maxAttempts: maxAttempts,
    decay: decay,
    key: key,
    responseBuilder: builder,
  );
}

/// Resolves the limit(s) for a request: a [Limit], a `List<Limit>` or
/// `null` (no limit).
typedef LimitResolver = FutureOr<Object?> Function(Request request);

/// Outcome of [RateLimitStore.attempt].
final class RateLimitResult {
  const RateLimitResult({
    required this.allowed,
    required this.limit,
    required this.remaining,
    required this.resetAt,
    this.retryAfter,
  });

  final bool allowed;
  final int limit;
  final int remaining;

  /// When the current window resets.
  final DateTime resetAt;

  /// How long to wait before the next attempt succeeds (when blocked).
  final Duration? retryAfter;
}

/// Backing store of attempt counters (ADR-003 scopes).
abstract interface class RateLimitStore {
  StateScope get scope;

  /// Records an attempt for [key] when under the limit.
  Future<RateLimitResult> attempt(String key, int maxAttempts, Duration decay);

  /// Attempts counted in the current window.
  Future<int> attempts(String key, Duration decay);

  /// Time until an attempt is possible again (zero when not limited).
  Future<Duration> availableIn(String key, int maxAttempts, Duration decay);

  Future<void> clear(String key);

  Future<void> flush();
}

/// Fixed-window counter of one key: Laravel's `RateLimiter` model (a hit
/// counter plus the time its window resets, started by the first hit).
final class _Bucket {
  _Bucket(this.resetAtMs);

  int hits = 0;
  final int resetAtMs;
}

/// Grant of [MemoryRateLimitStore.acquireSync]: how many of the requested
/// hits were recorded and the window they belong to.
final class RateLimitGrant {
  const RateLimitGrant({
    required this.granted,
    required this.hits,
    required this.resetAtMs,
  });

  /// Hits recorded (0 when the key is exhausted).
  final int granted;

  /// Hits in the window after this grant.
  final int hits;

  /// Epoch milliseconds when the window resets.
  final int resetAtMs;
}

/// Fixed-window counters in this isolate's memory, like Laravel's
/// `RateLimiter` (hits + reset time per key): O(1) time and two integers per
/// key, whatever the limit.
final class MemoryRateLimitStore implements RateLimitStore {
  MemoryRateLimitStore({DateTime Function()? clock, this.maxKeys = 100000})
    : _clock = clock ?? _utcNow;

  final DateTime Function() _clock;

  /// Keys retained before the least-recently-touched ones are evicted.
  final int maxKeys;
  final Map<String, _Bucket> _buckets = <String, _Bucket>{};

  @override
  StateScope get scope => StateScope.isolate;

  int get size => _buckets.length;

  /// Synchronous variant (used by the coordinator service). [cost] counts
  /// several hits at once; the attempt is all-or-nothing.
  RateLimitResult attemptSync(
    String key,
    int maxAttempts,
    Duration decay, {
    int cost = 1,
  }) {
    final now = _clock().millisecondsSinceEpoch;
    final bucket = _bucket(key, decay, now);
    final resetAt = DateTime.fromMillisecondsSinceEpoch(
      bucket.resetAtMs,
      isUtc: true,
    );
    if (bucket.hits + cost > maxAttempts) {
      return RateLimitResult(
        allowed: false,
        limit: maxAttempts,
        remaining: 0,
        resetAt: resetAt,
        retryAfter: Duration(milliseconds: bucket.resetAtMs - now),
      );
    }
    bucket.hits += cost;
    return RateLimitResult(
      allowed: true,
      limit: maxAttempts,
      remaining: maxAttempts - bucket.hits,
      resetAt: resetAt,
    );
  }

  /// Records up to [want] hits (fewer when the window is nearly full); used
  /// by workers to lease a batch of hits in one coordinator round trip.
  RateLimitGrant acquireSync(
    String key,
    int maxAttempts,
    Duration decay,
    int want,
  ) {
    final now = _clock().millisecondsSinceEpoch;
    final bucket = _bucket(key, decay, now);
    final free = maxAttempts - bucket.hits;
    final granted = free <= 0 ? 0 : (want < free ? want : free);
    bucket.hits += granted;
    return RateLimitGrant(
      granted: granted,
      hits: bucket.hits,
      resetAtMs: bucket.resetAtMs,
    );
  }

  /// Gives back [count] unused leased hits of the window ending at
  /// [resetAtMs] (ignored once that window is over).
  /// Returns the hits left in the window.
  int releaseSync(String key, int count, int resetAtMs) {
    final bucket = _buckets[key];
    if (bucket == null || bucket.resetAtMs != resetAtMs) {
      return 0;
    }
    bucket.hits = bucket.hits > count ? bucket.hits - count : 0;
    return bucket.hits;
  }

  int attemptsSync(String key, Duration decay) {
    final bucket = _buckets[key];
    final now = _clock().millisecondsSinceEpoch;
    return bucket == null || now >= bucket.resetAtMs ? 0 : bucket.hits;
  }

  Duration availableInSync(String key, int maxAttempts, Duration decay) {
    final bucket = _buckets[key];
    final now = _clock().millisecondsSinceEpoch;
    if (bucket == null ||
        now >= bucket.resetAtMs ||
        bucket.hits < maxAttempts) {
      return Duration.zero;
    }
    return Duration(milliseconds: bucket.resetAtMs - now);
  }

  @override
  Future<RateLimitResult> attempt(
    String key,
    int maxAttempts,
    Duration decay,
  ) async => attemptSync(key, maxAttempts, decay);

  @override
  Future<int> attempts(String key, Duration decay) async =>
      attemptsSync(key, decay);

  @override
  Future<Duration> availableIn(
    String key,
    int maxAttempts,
    Duration decay,
  ) async => availableInSync(key, maxAttempts, decay);

  @override
  Future<void> clear(String key) async => _buckets.remove(key);

  @override
  Future<void> flush() async => _buckets.clear();

  /// The live bucket of [key], starting a new window when the previous one
  /// expired; keeps keys in least-recently-used order for eviction.
  _Bucket _bucket(String key, Duration decay, int now) {
    var bucket = _buckets.remove(key);
    if (bucket == null || now >= bucket.resetAtMs) {
      bucket = _Bucket(now + decay.inMilliseconds);
    }
    _buckets[key] = bucket;
    if (_buckets.length > maxKeys) {
      _buckets.remove(_buckets.keys.first);
    }
    return bucket;
  }

  static DateTime _utcNow() => Clock.now().toUtc();
}

/// Coordinator service exposing a [MemoryRateLimitStore] to every worker.
final class RateLimitService implements CoordinatorService {
  RateLimitService([MemoryRateLimitStore? store])
    : store = store ?? MemoryRateLimitStore();

  static const String serviceName = 'rateLimiter';

  final MemoryRateLimitStore store;

  @override
  String get name => serviceName;

  @override
  Object? handle(String op, Map<String, Object?> args) {
    final key = args['key'] as String;
    final decay = Duration(milliseconds: args['decay'] as int? ?? 0);
    final max = args['max'] as int? ?? 0;
    return switch (op) {
      'attempt' => store.attemptSync(key, max, decay),
      'acquire' => store.acquireSync(key, max, decay, args['want'] as int),
      'release' => store.releaseSync(
        key,
        args['count'] as int,
        args['resetAt'] as int,
      ),
      'attempts' => store.attemptsSync(key, decay),
      'availableIn' => store.availableInSync(key, max, decay).inMilliseconds,
      'clear' => store.clear(key),
      'flush' => store.flush(),
      _ => throw CoordinatorException('Unknown rateLimiter op [$op].'),
    };
  }

  @override
  Map<String, Object?> stats() => <String, Object?>{'keys': store.size};
}

/// Hits a worker leased from the coordinator for one key.
final class _Lease {
  _Lease(this.tokens, this.limit, this.hits, this.resetAtMs, this.expiresAt);

  int tokens;
  final int limit;

  /// Coordinator hits after the lease (includes the leased tokens).
  final int hits;
  final int resetAtMs;

  /// Monotonic microseconds after which unused tokens go back.
  final int expiresAt;
}

/// Process-wide counters via the coordinator. Fails **open** on coordinator
/// errors/timeouts (the request is allowed and [onError] is notified), the
/// documented default for rate limiting (§5.2).
///
/// Across isolates, hot keys with generous limits are served from local
/// leases: a worker takes a batch of hits in one round trip and spends them
/// in memory. The batch starts at 1, doubles while leases are used up within
/// [leaseTtl] and resets when they are not; unused hits are released back,
/// so the limit is never exceeded nor under-delivered. Keys with fewer than
/// [leaseThreshold] attempts (login limits) always go to the coordinator. A
/// worker that saw a key blocked answers `429` locally for up to
/// [blockedCacheTtl] instead of asking again.
final class ProcessRateLimitStore implements RateLimitStore {
  ProcessRateLimitStore(
    this.channel, {
    this.timeout = const Duration(milliseconds: 50),
    this.onError,
    this.leaseThreshold = 32,
    this.maxLease = 16,
    this.leaseTtl = const Duration(milliseconds: 200),
    this.blockedCacheTtl = const Duration(milliseconds: 100),
  });

  final CoordinatorChannel channel;
  final Duration timeout;
  final void Function(Object error)? onError;

  /// Smallest `maxAttempts` served from leases.
  final int leaseThreshold;

  /// Largest batch leased at once.
  final int maxLease;

  /// Lifetime of a lease before unused hits are released.
  final Duration leaseTtl;

  /// How long a worker remembers that a key is blocked.
  final Duration blockedCacheTtl;

  final Map<String, _Lease> _leases = <String, _Lease>{};
  final Map<String, int> _batch = <String, int>{};
  final Map<String, (int, RateLimitResult)> _blocked =
      <String, (int, RateLimitResult)>{};
  final Stopwatch _monotonic = Stopwatch()..start();

  @override
  StateScope get scope => StateScope.process;

  Future<Object?> _call(String op, Map<String, Object?> args) => channel.call(
    RateLimitService.serviceName,
    op,
    args,
    timeout: channel.isRemote ? timeout : const Duration(seconds: 5),
  );

  @override
  Future<RateLimitResult> attempt(
    String key,
    int maxAttempts,
    Duration decay,
  ) async {
    try {
      if (!channel.isRemote || maxAttempts < leaseThreshold) {
        return await _call('attempt', {
          'key': key,
          'max': maxAttempts,
          'decay': decay.inMilliseconds,
        }) as RateLimitResult;
      }
      return await _leased(key, maxAttempts, decay);
    } on CoordinatorException catch (error) {
      onError?.call(error);
      return RateLimitResult(
        allowed: true,
        limit: maxAttempts,
        remaining: maxAttempts - 1,
        resetAt: Clock.now().toUtc().add(decay),
      );
    }
  }

  Future<RateLimitResult> _leased(
    String key,
    int maxAttempts,
    Duration decay,
  ) async {
    final now = _monotonic.elapsedMicroseconds;
    final blocked = _blocked[key];
    if (blocked != null) {
      if (now < blocked.$1) {
        return blocked.$2;
      }
      _blocked.remove(key);
    }
    var lease = _leases[key];
    if (lease != null &&
        (now >= lease.expiresAt || lease.limit != maxAttempts)) {
      _retire(key, lease, usedUp: false);
      lease = null;
    }
    if (lease == null || lease.tokens == 0) {
      if (lease != null) {
        _retire(key, lease, usedUp: true);
      }
      lease = await _acquire(key, maxAttempts, decay, now);
      if (lease == null) {
        return _blocked[key]!.$2;
      }
    }
    lease.tokens--;
    return RateLimitResult(
      allowed: true,
      limit: maxAttempts,
      remaining: maxAttempts - lease.hits + lease.tokens,
      resetAt: DateTime.fromMillisecondsSinceEpoch(
        lease.resetAtMs,
        isUtc: true,
      ),
    );
  }

  Future<_Lease?> _acquire(
    String key,
    int maxAttempts,
    Duration decay,
    int now,
  ) async {
    final grant = await _call('acquire', {
      'key': key,
      'max': maxAttempts,
      'decay': decay.inMilliseconds,
      'want': _batch[key] ?? 1,
    }) as RateLimitGrant;
    if (grant.granted == 0) {
      final wallNow = Clock.now().toUtc().millisecondsSinceEpoch;
      final retryMs = grant.resetAtMs - wallNow;
      final result = RateLimitResult(
        allowed: false,
        limit: maxAttempts,
        remaining: 0,
        resetAt: DateTime.fromMillisecondsSinceEpoch(
          grant.resetAtMs,
          isUtc: true,
        ),
        retryAfter: Duration(milliseconds: retryMs < 0 ? 0 : retryMs),
      );
      final ttl = blockedCacheTtl.inMicroseconds;
      final untilReset = retryMs * 1000;
      _blocked[key] = (now + (untilReset < ttl ? untilReset : ttl), result);
      _batch.remove(key);
      return null;
    }
    return _leases[key] = _Lease(
      grant.granted,
      maxAttempts,
      grant.hits,
      grant.resetAtMs,
      now + leaseTtl.inMicroseconds,
    );
  }

  /// Retires [lease]: returns unused hits and adapts the next batch size
  /// (doubles when the lease was used up in time, back to 1 otherwise).
  void _retire(String key, _Lease lease, {required bool usedUp}) {
    _leases.remove(key);
    final current = _batch[key] ?? 1;
    if (usedUp) {
      _batch[key] = current * 2 > maxLease ? maxLease : current * 2;
      return;
    }
    _batch.remove(key);
    if (lease.tokens > 0) {
      unawaited(
        _call('release', {
          'key': key,
          'count': lease.tokens,
          'resetAt': lease.resetAtMs,
        }).then<void>((_) {}, onError: (Object error) => onError?.call(error)),
      );
    }
  }

  @override
  Future<int> attempts(String key, Duration decay) async =>
      await _call('attempts', {'key': key, 'decay': decay.inMilliseconds})
          as int;

  @override
  Future<Duration> availableIn(
    String key,
    int maxAttempts,
    Duration decay,
  ) async => Duration(
    milliseconds: await _call('availableIn', {
      'key': key,
      'max': maxAttempts,
      'decay': decay.inMilliseconds,
    }) as int,
  );

  @override
  Future<void> clear(String key) {
    _leases.remove(key);
    _batch.remove(key);
    _blocked.remove(key);
    return _call('clear', {'key': key});
  }

  @override
  Future<void> flush() {
    _leases.clear();
    _batch.clear();
    _blocked.clear();
    return _call('flush', {'key': ''});
  }
}

/// Named limiters + counters (Laravel `RateLimiter`; BLUEPRINT_V2 §7.7).
final class RateLimiter {
  RateLimiter({RateLimitStore? store})
    : store = store ?? MemoryRateLimitStore();

  final RateLimitStore store;
  final Map<String, LimitResolver> _limiters = <String, LimitResolver>{};

  /// Registers a named limiter (`RateLimiter::for('api', fn)`).
  void define(String name, LimitResolver resolver) =>
      _limiters[name] = resolver;

  LimitResolver? limiter(String name) => _limiters[name];

  bool hasLimiter(String name) => _limiters.containsKey(name);

  /// Resolves the limits of named limiter [name] for [request].
  Future<List<Limit>> limitsFor(String name, Request request) async {
    final resolver = _limiters[name];
    if (resolver == null) {
      throw StateError(
        'Rate limiter [$name] is not defined. Register it with '
        "RateLimiter.define('$name', (request) => Limit.perMinute(60)).",
      );
    }
    final resolved = await resolver(request);
    return switch (resolved) {
      null => const <Limit>[],
      Limit() => <Limit>[resolved],
      List<Object?>() => resolved.cast<Limit>(),
      _ => throw StateError(
        'Rate limiter [$name] must return a Limit, a List<Limit> or null.',
      ),
    };
  }

  Future<RateLimitResult> attempt(
    String key,
    int maxAttempts,
    Duration decay,
  ) => store.attempt(key, maxAttempts, decay);

  Future<int> attempts(String key, Duration decay) =>
      store.attempts(key, decay);

  Future<bool> tooManyAttempts(
    String key,
    int maxAttempts,
    Duration decay,
  ) async => await attempts(key, decay) >= maxAttempts;

  Future<int> remaining(String key, int maxAttempts, Duration decay) async {
    final left = maxAttempts - await attempts(key, decay);
    return left < 0 ? 0 : left;
  }

  Future<Duration> availableIn(String key, int maxAttempts, Duration decay) =>
      store.availableIn(key, maxAttempts, decay);

  Future<void> clear(String key) => store.clear(key);

  Future<void> flush() => store.flush();
}

/// 429 with `Retry-After` and `X-RateLimit-*` headers.
final class ThrottleRequestsException extends HttpException {
  const ThrottleRequestsException({
    String message = 'Too Many Attempts.',
    super.headers,
  }) : super(429, message);
}

/// `throttle:60,1` (max attempts, decay minutes) or `throttle:api`
/// (named limiter). Adds `X-RateLimit-Limit`/`X-RateLimit-Remaining` to
/// responses and answers 429 with `Retry-After` when exceeded.
final class ThrottleMiddleware implements Middleware {
  const ThrottleMiddleware({
    this.maxAttempts = 60,
    this.decay = const Duration(minutes: 1),
    this.limiterName,
    this.prefix = '',
    this.limiter,
    this.userKeyResolver,
  });

  /// Parses alias parameters (`['60', '1']` or `['api']`).
  factory ThrottleMiddleware.fromParams(
    List<String> params, {
    RateLimiter? limiter,
    FutureOr<Object?> Function(Request request)? userKeyResolver,
  }) {
    if (params.isEmpty) {
      return ThrottleMiddleware(
        limiter: limiter,
        userKeyResolver: userKeyResolver,
      );
    }
    final max = int.tryParse(params.first);
    if (max == null) {
      return ThrottleMiddleware(
        limiterName: params.first,
        limiter: limiter,
        userKeyResolver: userKeyResolver,
      );
    }
    final minutes = params.length > 1 ? double.tryParse(params[1]) ?? 1 : 1;
    return ThrottleMiddleware(
      maxAttempts: max,
      decay: Duration(milliseconds: (minutes * 60000).round()),
      limiter: limiter,
      userKeyResolver: userKeyResolver,
    );
  }

  final int maxAttempts;
  final Duration decay;
  final String? limiterName;

  /// Key prefix separating independent throttles sharing a resolver.
  final String prefix;
  final RateLimiter? limiter;

  /// Returns the authenticated user's id (or `null` for guests) so limits
  /// follow the user instead of the IP.
  final FutureOr<Object?> Function(Request request)? userKeyResolver;

  @override
  Future<Response> handle(Request request, Next next) async {
    final limiter = this.limiter ?? _defaultLimiter;
    final name = limiterName;
    final limits = name == null
        ? <Limit>[Limit(maxAttempts: maxAttempts, decay: decay)]
        : await limiter.limitsFor(name, request);
    final headers = <String, String>{};
    for (final limit in limits) {
      if (limit.isUnlimited) {
        continue;
      }
      final key =
          '$prefix${name ?? ''}:${limit.key ?? await _signature(request)}';
      final result = await limiter.attempt(key, limit.maxAttempts, limit.decay);
      if (!result.allowed) {
        final retry = result.retryAfter ?? Duration.zero;
        final seconds = (retry.inMilliseconds / 1000).ceil();
        final blocked = <String, String>{
          'retry-after': '$seconds',
          'x-ratelimit-limit': '${result.limit}',
          'x-ratelimit-remaining': '0',
          'x-ratelimit-reset':
              '${result.resetAt.millisecondsSinceEpoch ~/ 1000}',
        };
        final builder = limit.responseBuilder;
        if (builder != null) {
          return builder(request, blocked);
        }
        throw ThrottleRequestsException(headers: blocked);
      }
      final current = int.tryParse(headers['x-ratelimit-remaining'] ?? '');
      if (current == null || result.remaining < current) {
        headers['x-ratelimit-limit'] = '${result.limit}';
        headers['x-ratelimit-remaining'] = '${result.remaining}';
      }
    }
    final response = await next(request);
    return headers.isEmpty ? response : response.withHeaders(headers);
  }

  Future<String> _signature(Request request) async {
    final user = await userKeyResolver?.call(request);
    if (user != null) {
      return 'user:$user';
    }
    return '${request.method}|${request.host}|${request.path}|${request.ip}';
  }

  static final RateLimiter _defaultLimiter = RateLimiter();
}
