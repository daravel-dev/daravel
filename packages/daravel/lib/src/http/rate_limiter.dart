import 'dart:async';
import '../foundation/clock.dart';

import '../server/coordinator.dart';
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

  /// When the oldest counted attempt leaves the window.
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

/// Sliding-window-log counters in this isolate's memory.
final class MemoryRateLimitStore implements RateLimitStore {
  MemoryRateLimitStore({DateTime Function()? clock, this.maxKeys = 100000})
    : _clock = clock ?? _utcNow;

  final DateTime Function() _clock;

  /// Keys retained before the least-recently-touched ones are evicted.
  final int maxKeys;
  final Map<String, List<int>> _hits = <String, List<int>>{};

  @override
  StateScope get scope => StateScope.isolate;

  int get size => _hits.length;

  /// Synchronous variant (used by the coordinator service).
  RateLimitResult attemptSync(String key, int maxAttempts, Duration decay) {
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

  int attemptsSync(String key, Duration decay) =>
      _window(key, decay, _clock().millisecondsSinceEpoch).length;

  Duration availableInSync(String key, int maxAttempts, Duration decay) {
    final now = _clock().millisecondsSinceEpoch;
    final window = _window(key, decay, now);
    if (window.length < maxAttempts) {
      return Duration.zero;
    }
    return Duration(milliseconds: window.first + decay.inMilliseconds - now);
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
  Future<void> clear(String key) async => _hits.remove(key);

  @override
  Future<void> flush() async => _hits.clear();

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

/// Process-wide counters via the coordinator. Fails **open** on coordinator
/// errors/timeouts (the request is allowed and [onError] is notified), the
/// documented default for rate limiting (§5.2).
final class ProcessRateLimitStore implements RateLimitStore {
  ProcessRateLimitStore(
    this.channel, {
    this.timeout = const Duration(milliseconds: 50),
    this.onError,
  });

  final CoordinatorChannel channel;
  final Duration timeout;
  final void Function(Object error)? onError;

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
      return await _call('attempt', {
            'key': key,
            'max': maxAttempts,
            'decay': decay.inMilliseconds,
          })
          as RateLimitResult;
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
    milliseconds:
        await _call('availableIn', {
              'key': key,
              'max': maxAttempts,
              'decay': decay.inMilliseconds,
            })
            as int,
  );

  @override
  Future<void> clear(String key) => _call('clear', {'key': key});

  @override
  Future<void> flush() => _call('flush', {'key': ''});
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
