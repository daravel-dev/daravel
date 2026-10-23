import 'dart:async';

import 'http_exceptions.dart';
import 'middleware.dart';
import 'request.dart';
import 'response.dart';

/// Builds the 429 response for a limit (`Limit.response`).
typedef ThrottleResponseBuilder =
    Response Function(Request request, Map<String, String> headers);

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

/// Outcome of [RateLimiter.attempt].
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

  /// When the oldest counted attempt leaves the window.
  final DateTime resetAt;

  /// How long to wait before the next attempt succeeds (when blocked).
  final Duration? retryAfter;
}

/// Sliding-window-log rate limiter, in-memory per isolate (S9 adds the
/// process/cluster scopes; BLUEPRINT_V2 §7.7).
final class RateLimiter {
  RateLimiter({DateTime Function()? clock, this.maxKeys = 100000})
    : _clock = clock ?? _utcNow;

  final DateTime Function() _clock;

  /// Keys retained before the least-recently-touched ones are evicted.
  final int maxKeys;

  final Map<String, LimitResolver> _limiters = <String, LimitResolver>{};
  final Map<String, List<int>> _hits = <String, List<int>>{};

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

  /// Records an attempt for [key] when under the limit.
  RateLimitResult attempt(String key, int maxAttempts, Duration decay) {
    final now = _clock().millisecondsSinceEpoch;
    final window = _window(key, decay, now);
    if (window.length >= maxAttempts) {
      final resetMs = window.first + decay.inMilliseconds;
      return RateLimitResult(
        allowed: false,
        limit: maxAttempts,
        remaining: 0,
        resetAt: DateTime.fromMillisecondsSinceEpoch(resetMs, isUtc: true),
        retryAfter: Duration(milliseconds: resetMs - now),
      );
    }
    window.add(now);
    return RateLimitResult(
      allowed: true,
      limit: maxAttempts,
      remaining: maxAttempts - window.length,
      resetAt: DateTime.fromMillisecondsSinceEpoch(
        window.first + decay.inMilliseconds,
        isUtc: true,
      ),
    );
  }

  /// Attempts counted in the current window.
  int attempts(String key, Duration decay) =>
      _window(key, decay, _clock().millisecondsSinceEpoch).length;

  bool tooManyAttempts(String key, int maxAttempts, Duration decay) =>
      attempts(key, decay) >= maxAttempts;

  int remaining(String key, int maxAttempts, Duration decay) {
    final left = maxAttempts - attempts(key, decay);
    return left < 0 ? 0 : left;
  }

  /// Time until an attempt is possible again (zero when not limited).
  Duration availableIn(String key, int maxAttempts, Duration decay) {
    final now = _clock().millisecondsSinceEpoch;
    final window = _window(key, decay, now);
    if (window.length < maxAttempts) {
      return Duration.zero;
    }
    return Duration(milliseconds: window.first + decay.inMilliseconds - now);
  }

  void clear(String key) => _hits.remove(key);

  void flush() => _hits.clear();

  List<int> _window(String key, Duration decay, int now) {
    final existing = _hits.remove(key);
    final cutoff = now - decay.inMilliseconds;
    final window = existing == null
        ? <int>[]
        : existing.where((t) => t > cutoff).toList();
    _hits[key] = window; // re-insert → most recently used
    if (_hits.length > maxKeys) {
      _hits.remove(_hits.keys.first);
    }
    return window;
  }

  static DateTime _utcNow() => DateTime.now().toUtc();
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
      final result = limiter.attempt(key, limit.maxAttempts, limit.decay);
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
