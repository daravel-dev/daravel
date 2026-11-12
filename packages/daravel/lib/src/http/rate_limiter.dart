import 'dart:async';

import '../foundation/clock.dart';
import '../foundation/container.dart';
import '../foundation/detached.dart';
import '../foundation/shared_result.dart';

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

/// How a [Limit] counts attempts.
enum RateLimitAlgorithm {
  /// Laravel's: a window that starts with its first hit and resets at once,
  /// so up to twice the limit can pass around a reset.
  fixedWindow,

  /// The current window plus the previous one, weighted by how much of it
  /// is still within the decay: no burst at the reset.
  slidingWindow,

  /// Generic cell rate algorithm: the limit spread evenly over the decay
  /// (one attempt every decay / maxAttempts), with a burst of the whole
  /// limit after a quiet period.
  gcra,
}

/// A rate limit (Laravel `Illuminate\Cache\RateLimiting\Limit`).
final class Limit {
  /// At most [maxAttempts] per [decay], counted per [key] (the request's
  /// address by default).
  const Limit({
    required this.maxAttempts,
    required this.decay,
    this.key,
    this.responseBuilder,
    this.algorithm = RateLimitAlgorithm.fixedWindow,
    this.failClosed = false,
  });

  /// [maxAttempts] per [seconds] seconds.
  factory Limit.perSecond(int maxAttempts, [int seconds = 1]) => Limit(
    maxAttempts: maxAttempts,
    decay: Duration(seconds: seconds),
  );

  /// [maxAttempts] per [minutes] minutes: `Limit.perMinute(60)`.
  factory Limit.perMinute(int maxAttempts, [int minutes = 1]) => Limit(
    maxAttempts: maxAttempts,
    decay: Duration(minutes: minutes),
  );

  /// [maxAttempts] per [hours] hours.
  factory Limit.perHour(int maxAttempts, [int hours = 1]) => Limit(
    maxAttempts: maxAttempts,
    decay: Duration(hours: hours),
  );

  /// [maxAttempts] per [days] days.
  factory Limit.perDay(int maxAttempts, [int days = 1]) => Limit(
    maxAttempts: maxAttempts,
    decay: Duration(days: days),
  );

  /// No limit at all.
  const Limit.none()
    : maxAttempts = -1,
      decay = Duration.zero,
      key = null,
      responseBuilder = null,
      algorithm = RateLimitAlgorithm.fixedWindow,
      failClosed = false;

  /// The attempts allowed per window; negative for no limit.
  final int maxAttempts;

  /// The length of the window.
  final Duration decay;

  /// Segment key (user id, email+ip, …); defaults to the request signature.
  final Object? key;

  /// Builds the 429 response instead of the default one.
  final ThrottleResponseBuilder? responseBuilder;

  /// How attempts are counted: [RateLimitAlgorithm.fixedWindow] unless
  /// [slidingWindow] or [gcra] says otherwise. A store without that
  /// algorithm (an [AlgorithmRateLimitStore]) counts a fixed window.
  final RateLimitAlgorithm algorithm;

  /// Whether a request is refused (429) when the store cannot count it,
  /// rather than let through. Rate limiting fails open by default
  /// (ADR-003): a coordinator that times out must not take the site down.
  /// A limit guarding credentials (login, OTP, password reset) should fail
  /// closed, so that overloading the coordinator does not lift it.
  final bool failClosed;

  /// Whether this is [Limit.none].
  bool get isUnlimited => maxAttempts < 0;

  /// The same limit counted per [key]: `Limit.perMinute(5).by(email)`.
  Limit by(Object key) => Limit(
    maxAttempts: maxAttempts,
    decay: decay,
    key: key,
    responseBuilder: responseBuilder,
    algorithm: algorithm,
    failClosed: failClosed,
  );

  /// The same limit answering 429 with [builder]'s response.
  Limit response(ThrottleResponseBuilder builder) => Limit(
    maxAttempts: maxAttempts,
    decay: decay,
    key: key,
    responseBuilder: builder,
    algorithm: algorithm,
    failClosed: failClosed,
  );

  /// The same limit refusing requests the store cannot count
  /// ([failClosed]): `Limit.perMinute(5).by(email).failsClosed()`.
  Limit failsClosed() => Limit(
    maxAttempts: maxAttempts,
    decay: decay,
    key: key,
    responseBuilder: responseBuilder,
    algorithm: algorithm,
    failClosed: true,
  );

  /// Counts with [RateLimitAlgorithm.slidingWindow] (`CACHE_LIMITER=redis`
  /// with daravel_redis).
  Limit slidingWindow() => _counting(RateLimitAlgorithm.slidingWindow);

  /// Counts with [RateLimitAlgorithm.gcra] (`CACHE_LIMITER=redis` with
  /// daravel_redis).
  Limit gcra() => _counting(RateLimitAlgorithm.gcra);

  Limit _counting(RateLimitAlgorithm algorithm) => Limit(
    maxAttempts: maxAttempts,
    decay: decay,
    key: key,
    responseBuilder: responseBuilder,
    algorithm: algorithm,
    failClosed: failClosed,
  );
}

/// Resolves the limit(s) for a request: a [Limit], a `List<Limit>` or
/// `null` (no limit).
typedef LimitResolver = FutureOr<Object?> Function(Request request);

/// Outcome of [RateLimitStore.attempt].
final class RateLimitResult {
  /// Whether the attempt was [allowed], under [limit] with [remaining]
  /// left.
  const RateLimitResult({
    required this.allowed,
    required this.limit,
    required this.remaining,
    required this.resetAt,
    this.retryAfter,
    this.degraded = false,
  });

  /// An attempt refused because the store could not count it (a store or
  /// limit that fails closed): [degraded], told to retry after
  /// [ProcessRateLimitStore.failClosedRetryAfter].
  factory RateLimitResult.refusedUncounted(int maxAttempts) {
    const retry = ProcessRateLimitStore.failClosedRetryAfter;
    return RateLimitResult(
      allowed: false,
      limit: maxAttempts,
      remaining: 0,
      resetAt: Clock.now().toUtc().add(retry),
      retryAfter: retry,
      degraded: true,
    );
  }

  /// Whether the attempt was counted.
  final bool allowed;

  /// Whether the store could not reach its counters (a coordinator error or
  /// timeout), so this result was not counted anywhere: [allowed] is then
  /// the store's fallback, true when it fails open. [RateLimiter.attempt]
  /// with `failClosed` refuses such an attempt.
  final bool degraded;

  /// The attempts allowed per window.
  final int limit;

  /// The attempts left in the window.
  final int remaining;

  /// When the current window resets.
  final DateTime resetAt;

  /// How long to wait before the next attempt succeeds (when blocked).
  final Duration? retryAfter;
}

/// Backing store of attempt counters (ADR-003 scopes).
abstract interface class RateLimitStore {
  /// Where the counters live: one isolate, the process, or the cluster.
  StateScope get scope;

  /// Records an attempt for [key] when under the limit.
  Future<RateLimitResult> attempt(String key, int maxAttempts, Duration decay);

  /// Attempts counted in the current window.
  Future<int> attempts(String key, Duration decay);

  /// Time until an attempt is possible again (zero when not limited).
  Future<Duration> availableIn(String key, int maxAttempts, Duration decay);

  /// Forgets the attempts of [key].
  Future<void> clear(String key);

  /// Forgets every attempt.
  Future<void> flush();
}

/// A [RateLimitStore] that also counts with other algorithms than the
/// fixed window ([Limit.slidingWindow], [Limit.gcra]).
abstract interface class AlgorithmRateLimitStore implements RateLimitStore {
  /// Whether [algorithm] is counted as itself (else as a fixed window).
  bool supports(RateLimitAlgorithm algorithm);

  /// Records an attempt for [key] under [algorithm] when under the limit.
  Future<RateLimitResult> attemptWith(
    RateLimitAlgorithm algorithm,
    String key,
    int maxAttempts,
    Duration decay,
  );
}

/// Fixed-window counter of one key: Laravel's `RateLimiter` model (a hit
/// counter plus the time its window resets, started by the first hit).
final class _Bucket {
  _Bucket(this.resetAtMs);

  int hits = 0;
  final int resetAtMs;
}

/// Grant of [MemoryRateLimitStore.acquireSync]: how many of the requested
/// hits were recorded and the window they belong to. Deeply immutable, so
/// the coordinator's answer to a lease crosses back without a copy.
@pragma('vm:deeply-immutable')
final class RateLimitGrant implements CoordinatorMessage {
  /// A grant of [granted] hits, [hits] in the window resetting at
  /// [resetAtMs].
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
  /// A store keeping at most [maxKeys] keys; [clock] is for tests.
  MemoryRateLimitStore({DateTime Function()? clock, this.maxKeys = 100000})
    : _clock = clock ?? _utcNow;

  final DateTime Function() _clock;

  /// Keys retained before the least-recently-touched ones are evicted.
  final int maxKeys;
  final Map<String, _Bucket> _buckets = <String, _Bucket>{};

  /// Evictions left before the next sweep of windows that are over.
  int _evictionsBeforeSweep = 0;

  @override
  StateScope get scope => StateScope.isolate;

  /// The number of keys held.
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

  /// The attempts of [key] in the current window.
  int attemptsSync(String key, Duration decay) {
    final bucket = _buckets[key];
    final now = _clock().millisecondsSinceEpoch;
    return bucket == null || now >= bucket.resetAtMs ? 0 : bucket.hits;
  }

  /// The time until [key] may try again.
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
      if (_evictionsBeforeSweep-- <= 0) {
        // Windows that are over go before live ones, which are evicted only
        // under real pressure; one pass per maxKeys / 16 evictions keeps the
        // cost amortised.
        _buckets.removeWhere((_, b) => now >= b.resetAtMs);
        _evictionsBeforeSweep = maxKeys ~/ 16 < 1 ? 1 : maxKeys ~/ 16;
      }
      while (_buckets.length > maxKeys) {
        _buckets.remove(_buckets.keys.first);
      }
    }
    return bucket;
  }

  static DateTime _utcNow() => Clock.now().toUtc();
}

/// One call to [RateLimitService], as [ProcessRateLimitStore] sends it
/// through [TypedCoordinatorChannel.callTyped] (ADR-031): deeply
/// immutable, so it crosses to the coordinator isolate by reference where
/// the map of [toArgs] is copied entry by entry. [op] is an operation of
/// [RateLimitService.handle]; the fields an operation does not read are 0.
@pragma('vm:deeply-immutable')
final class RateLimitMessage implements ExpiringCoordinatorMessage {
  /// A call of [op] for [key].
  const RateLimitMessage(
    this.op,
    this.key, {
    this.max = 0,
    this.decayMs = 0,
    this.want = 0,
    this.count = 0,
    this.resetAt = 0,
  });

  /// `attempt`, `acquire`, `release`, `attempts`, `availableIn`, `clear` or
  /// `flush`.
  final String op;

  /// The limited key.
  final String key;

  /// The most attempts in a window.
  final int max;

  /// The window, in milliseconds.
  final int decayMs;

  /// The hits an `acquire` asks for.
  final int want;

  /// The unused hits a `release` gives back.
  final int count;

  /// Epoch milliseconds when the window of a `release` ends.
  final int resetAt;

  /// Counting and reading calls expire with the worker's wait: an attempt
  /// or a lease the worker already let through uncounted (or refused) is
  /// not counted later. A `release`, `clear` or `flush` never expires.
  @override
  bool get expiresWithCall => switch (op) {
    'attempt' || 'acquire' || 'attempts' || 'availableIn' => true,
    _ => false,
  };

  /// The same call as the arguments of [RateLimitService.handle], for a
  /// channel that is not a [TypedCoordinatorChannel].
  Map<String, Object?> toArgs() => <String, Object?>{
    'key': key,
    'max': max,
    'decay': decayMs,
    'want': want,
    'count': count,
    'resetAt': resetAt,
  };
}

/// Coordinator service exposing a [MemoryRateLimitStore] to every worker.
/// Workers send it [RateLimitMessage]s; [handle] answers the same
/// operations given as maps.
final class RateLimitService
    with PrioritizedService
    implements TypedCoordinatorService<RateLimitMessage> {
  /// Critical: answered at once even when the coordinator is behind.
  @override
  CoordinatorPriority get priority => CoordinatorPriority.critical;

  /// A service over [store], or a new memory store.
  RateLimitService([MemoryRateLimitStore? store])
    : store = store ?? MemoryRateLimitStore();

  /// The coordinator service name.
  static const String serviceName = 'rateLimiter';

  /// The counters every worker shares.
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
  Object? handleTyped(RateLimitMessage message) {
    final key = message.key;
    final max = message.max;
    return switch (message.op) {
      'attempt' => store.attemptSync(
        key,
        max,
        Duration(milliseconds: message.decayMs),
      ),
      'acquire' => store.acquireSync(
        key,
        max,
        Duration(milliseconds: message.decayMs),
        message.want,
      ),
      'release' => store.releaseSync(key, message.count, message.resetAt),
      'attempts' => store.attemptsSync(
        key,
        Duration(milliseconds: message.decayMs),
      ),
      'availableIn' =>
        store
            .availableInSync(key, max, Duration(milliseconds: message.decayMs))
            .inMilliseconds,
      'clear' => store.clear(key),
      'flush' => store.flush(),
      final op => throw CoordinatorException('Unknown rateLimiter op [$op].'),
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
/// documented default for rate limiting (§5.2), unless [failClosed]. Either
/// way the result is [RateLimitResult.degraded], so a [Limit.failClosed]
/// limit refuses it even in a store that fails open.
///
/// Across isolates, hot keys with generous limits are served from local
/// leases: a worker takes a batch of hits in one round trip and spends them
/// in memory. The batch starts at 1, doubles while leases are used up within
/// [leaseTtl] and resets when they are not; unused hits are released back,
/// so the limit is never exceeded nor under-delivered. Keys with fewer than
/// [leaseThreshold] attempts (login limits) always go to the coordinator. A
/// worker that saw a key blocked answers `429` locally for up to
/// [blockedCacheTtl] instead of asking again.
///
/// Concurrent attempts on one key share a single lease request: while one
/// is in flight the others wait for it and spend its hits, and the next
/// request asks for as many hits as there are waiters (up to [maxLease]).
/// A timer retires expired leases every [leaseTtl], so a worker that goes
/// quiet gives its unused hits back. A lease whose answer arrives after
/// [timeout] is given back as soon as it arrives.
final class ProcessRateLimitStore implements RateLimitStore {
  /// Counters held by the coordinator through [channel], waiting at most
  /// [timeout] for an answer.
  ProcessRateLimitStore(
    this.channel, {
    this.timeout = const Duration(milliseconds: 50),
    this.onError,
    this.leaseThreshold = 32,
    this.maxLease = 16,
    this.leaseTtl = const Duration(milliseconds: 200),
    this.blockedCacheTtl = const Duration(milliseconds: 100),
    this.maxKeys = 10000,
    this.failClosed = false,
  });

  /// The channel to the coordinator.
  final CoordinatorChannel channel;

  /// How long to wait for the coordinator before letting a request through
  /// (or refusing it, when [failClosed]).
  final Duration timeout;

  /// Called when the coordinator fails or times out.
  final void Function(Object error)? onError;

  /// Whether every attempt the coordinator cannot count is refused, for
  /// every limit, instead of let through. [Limit.failClosed] does it for
  /// one limit only.
  final bool failClosed;

  /// How long a refused attempt is told to wait when the coordinator could
  /// not count it ([failClosed]).
  static const Duration failClosedRetryAfter = Duration(seconds: 1);

  /// Smallest `maxAttempts` served from leases.
  final int leaseThreshold;

  /// Largest batch leased at once.
  final int maxLease;

  /// Lifetime of a lease before unused hits are released.
  final Duration leaseTtl;

  /// How long a worker remembers that a key is blocked.
  final Duration blockedCacheTtl;

  /// Keys this worker keeps state for (leases, blocks, batch sizes) before
  /// the expired ones are swept. Every key the worker ever limited (one per
  /// client IP, say) used to stay until it was asked for again.
  final int maxKeys;

  final Map<String, _Lease> _leases = <String, _Lease>{};
  final Map<String, int> _batch = <String, int>{};
  final Map<String, (int, RateLimitResult)> _blocked =
      <String, (int, RateLimitResult)>{};
  final Stopwatch _monotonic = Stopwatch()..start();

  /// The lease request in flight per key (single flight).
  final Map<String, SharedResult<void>> _acquiring =
      <String, SharedResult<void>>{};

  /// Attempts waiting for the lease request of their key.
  final Map<String, int> _waiting = <String, int>{};

  /// Retires expired leases and blocks every [leaseTtl] while there are
  /// any, detached from the request whose lease starts it (Review #149).
  Detached<Timer>? _reaper;

  /// How long a lease request may still be answered after [timeout], so
  /// that a late grant is given back instead of lost.
  static const Duration lateGrantTimeout = Duration(seconds: 5);

  /// Keys with state on this worker.
  int get trackedKeys =>
      {..._leases.keys, ..._batch.keys, ..._blocked.keys}.length;

  /// Drops what has expired once [maxKeys] is reached: leases past their
  /// lifetime (their unused hits go back to the coordinator) and blocks
  /// past theirs. Batch sizes have no expiry: the map is kept in order of
  /// last use and its older half goes when it is full, so a hot key
  /// (refreshed at every lease) keeps its size and a key seen once does
  /// not.
  void _sweep(int now) {
    if (_leases.length >= maxKeys) {
      for (final entry in _leases.entries.toList()) {
        if (now >= entry.value.expiresAt) {
          _retire(entry.key, entry.value, usedUp: false);
        }
      }
    }
    if (_blocked.length >= maxKeys) {
      _blocked.removeWhere((_, blocked) => now >= blocked.$1);
    }
    if (_batch.length >= maxKeys) {
      for (final key in _batch.keys.take(_batch.length ~/ 2).toList()) {
        _batch.remove(key);
      }
    }
  }

  @override
  StateScope get scope => StateScope.process;

  /// Sends [message] typed, or as a map to a channel that is only a
  /// [CoordinatorChannel].
  Future<Object?> _call(RateLimitMessage message, {Duration? wait}) {
    final target = channel;
    // Always asked, whatever the coordinator's state: a rate limit is
    // critical, served at once in every state, and with the bulk credit
    // window (K1b) it no longer waits behind a flood. Failing it here when
    // the coordinator said "saturated" turned limits off on a merely busy
    // host (Blueprint #141 §6.6); only its own [timeout] applies the
    // limit's failure policy now, as before K1.
    wait ??= target.isRemote ? timeout : const Duration(seconds: 5);
    return target is TypedCoordinatorChannel
        ? target.callTyped(RateLimitService.serviceName, message, timeout: wait)
        : target.call(
            RateLimitService.serviceName,
            message.op,
            message.toArgs(),
            timeout: wait,
          );
  }

  @override
  Future<RateLimitResult> attempt(
    String key,
    int maxAttempts,
    Duration decay,
  ) async {
    try {
      if (!channel.isRemote || maxAttempts < leaseThreshold) {
        return await _call(
          RateLimitMessage(
            'attempt',
            key,
            max: maxAttempts,
            decayMs: decay.inMilliseconds,
          ),
        ) as RateLimitResult;
      }
      return await _leased(key, maxAttempts, decay);
    } on CoordinatorException catch (error) {
      onError?.call(error);
      return failClosed
          ? RateLimitResult.refusedUncounted(maxAttempts)
          : RateLimitResult(
              allowed: true,
              limit: maxAttempts,
              remaining: maxAttempts - 1,
              resetAt: Clock.now().toUtc().add(decay),
              degraded: true,
            );
    }
  }

  Future<RateLimitResult> _leased(
    String key,
    int maxAttempts,
    Duration decay,
  ) async {
    while (true) {
      final now = _monotonic.elapsedMicroseconds;
      _sweep(now);
      final blocked = _blocked[key];
      if (blocked != null) {
        if (now < blocked.$1) {
          return blocked.$2;
        }
        _blocked.remove(key);
      }
      final lease = _leases[key];
      if (lease != null) {
        if (now >= lease.expiresAt || lease.limit != maxAttempts) {
          _retire(key, lease, usedUp: false);
        } else if (lease.tokens > 0) {
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
        } else {
          _retire(key, lease, usedUp: true);
        }
      }
      // Single flight: concurrent misses wait for the request in flight
      // and spend its lease, instead of each leasing (and overwriting) its
      // own batch.
      final inFlight = _acquiring[key];
      if (inFlight != null) {
        _waiting[key] = (_waiting[key] ?? 0) + 1;
        try {
          // Its error, if any, raised here in this caller's zone: the
          // attempts of other requests wait on it too.
          await inFlight.value;
        } finally {
          final left = (_waiting[key] ?? 1) - 1;
          if (left > 0) {
            _waiting[key] = left;
          } else {
            _waiting.remove(key);
          }
        }
        continue;
      }
      // Shared with the concurrent misses of other requests, so it never
      // fails as a future (an error would not reach a request waiting from
      // another zone, which would hang instead of failing open).
      final acquiring = SharedResult<void>(
        () => _acquire(key, maxAttempts, decay, now),
      );
      _acquiring[key] = acquiring;
      try {
        await acquiring.value;
      } finally {
        if (identical(_acquiring[key], acquiring)) {
          _acquiring.remove(key);
        }
      }
    }
  }

  /// Leases hits of [key] from the coordinator: as many as the batch size
  /// or the attempts waiting for them, whichever is larger, up to
  /// [maxLease]. Stores the lease, or the block when none is left.
  Future<void> _acquire(
    String key,
    int maxAttempts,
    Duration decay,
    int now,
  ) async {
    final batch = _batch[key] ?? 1;
    final demand = 1 + (_waiting[key] ?? 0);
    final wanted = demand > batch ? demand : batch;
    final pending = _call(
      RateLimitMessage(
        'acquire',
        key,
        max: maxAttempts,
        decayMs: decay.inMilliseconds,
        want: wanted > maxLease ? maxLease : wanted,
      ),
      wait: lateGrantTimeout,
    );
    final RateLimitGrant grant;
    try {
      grant = await pending.timeout(timeout) as RateLimitGrant;
    } on TimeoutException {
      // The request goes through uncounted (or refused, failing closed);
      // the coordinator may still grant the lease, and its hits then go
      // back as soon as the late answer arrives instead of being lost.
      unawaited(
        pending.then<void>((Object? late) {
          if (late is RateLimitGrant && late.granted > 0) {
            _release(key, late.granted, late.resetAtMs);
          }
        }, onError: (Object _) {}),
      );
      throw CoordinatorTimeoutException(RateLimitService.serviceName, timeout);
    }
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
      _startReaper();
      return;
    }
    final replaced = _leases[key];
    if (replaced != null) {
      // Not expected with one request in flight per key, but a lease with
      // hits left must never be dropped without giving them back.
      _retire(key, replaced, usedUp: false);
    }
    _leases[key] = _Lease(
      grant.granted,
      maxAttempts,
      grant.hits,
      grant.resetAtMs,
      _monotonic.elapsedMicroseconds + leaseTtl.inMicroseconds,
    );
    _startReaper();
  }

  /// Starts the timer that retires expired leases and blocks.
  void _startReaper() => _reaper ??= runDetached(
    () => Timer.periodic(leaseTtl, (_) => retireExpired()),
    name: 'rate limit lease reaper',
  );

  /// Gives back the unused hits of every expired lease and forgets expired
  /// blocks. A timer calls it every [leaseTtl] while this worker holds
  /// either, so a worker that goes quiet does not keep part of a window.
  void retireExpired() {
    final now = _monotonic.elapsedMicroseconds;
    for (final entry in _leases.entries.toList()) {
      if (now >= entry.value.expiresAt) {
        _retire(entry.key, entry.value, usedUp: false);
      }
    }
    _blocked.removeWhere((_, blocked) => now >= blocked.$1);
    if (_leases.isEmpty && _blocked.isEmpty) {
      _reaper?.cancel().ignore();
      _reaper = null;
    }
  }

  /// Retires [lease]: returns unused hits and adapts the next batch size
  /// (doubles when the lease was used up in time, back to 1 otherwise).
  void _retire(String key, _Lease lease, {required bool usedUp}) {
    if (identical(_leases[key], lease)) {
      _leases.remove(key);
    }
    final current = _batch.remove(key) ?? 1;
    if (usedUp) {
      // Re-inserted: the most recently used key is last (see _sweep).
      _batch[key] = current * 2 > maxLease ? maxLease : current * 2;
      return;
    }
    if (lease.tokens > 0) {
      _release(key, lease.tokens, lease.resetAtMs);
      lease.tokens = 0;
    }
  }

  /// Gives [count] leased hits of the window ending at [resetAtMs] back.
  void _release(String key, int count, int resetAtMs) => unawaited(
    _call(RateLimitMessage('release', key, count: count, resetAt: resetAtMs))
        .then<void>((_) {}, onError: (Object error) => onError?.call(error)),
  );

  @override
  Future<int> attempts(String key, Duration decay) async => await _call(
    RateLimitMessage('attempts', key, decayMs: decay.inMilliseconds),
  ) as int;

  @override
  Future<Duration> availableIn(
    String key,
    int maxAttempts,
    Duration decay,
  ) async => Duration(
    milliseconds: await _call(
      RateLimitMessage(
        'availableIn',
        key,
        max: maxAttempts,
        decayMs: decay.inMilliseconds,
      ),
    ) as int,
  );

  @override
  Future<void> clear(String key) {
    _leases.remove(key);
    _batch.remove(key);
    _blocked.remove(key);
    return _call(RateLimitMessage('clear', key));
  }

  @override
  Future<void> flush() {
    _leases.clear();
    _batch.clear();
    _blocked.clear();
    return _call(const RateLimitMessage('flush', ''));
  }
}

/// Named limiters + counters (Laravel `RateLimiter`; BLUEPRINT_V2 §7.7).
final class RateLimiter {
  /// A limiter counting in [store] (memory by default).
  RateLimiter({RateLimitStore? store})
    : store = store ?? MemoryRateLimitStore();

  /// Where the attempts are counted.
  final RateLimitStore store;
  final Map<String, LimitResolver> _limiters = <String, LimitResolver>{};

  /// Registers a named limiter (`RateLimiter::for('api', fn)`).
  void define(String name, LimitResolver resolver) =>
      _limiters[name] = resolver;

  /// The limiter registered as [name], or null.
  LimitResolver? limiter(String name) => _limiters[name];

  /// The names of the registered limiters (read only; `dartisan
  /// names:sync` writes `RateLimiters.*` from them).
  Iterable<String> get names => _limiters.keys;

  /// Whether a limiter is registered as [name].
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

  /// Records an attempt; [algorithm] counts it as [Limit.slidingWindow] or
  /// [Limit.gcra] where the store can, else as a fixed window. With
  /// [failClosed], an attempt the store let through without counting it
  /// ([RateLimitResult.degraded]) is refused instead.
  Future<RateLimitResult> attempt(
    String key,
    int maxAttempts,
    Duration decay, {
    RateLimitAlgorithm algorithm = RateLimitAlgorithm.fixedWindow,
    bool failClosed = false,
  }) async {
    final store = this.store;
    final result =
        algorithm != RateLimitAlgorithm.fixedWindow &&
            store is AlgorithmRateLimitStore &&
            store.supports(algorithm)
        ? await store.attemptWith(algorithm, key, maxAttempts, decay)
        : await store.attempt(key, maxAttempts, decay);
    return failClosed && result.degraded && result.allowed
        ? RateLimitResult.refusedUncounted(maxAttempts)
        : result;
  }

  /// The attempts of [key] in the current window.
  Future<int> attempts(String key, Duration decay) =>
      store.attempts(key, decay);

  /// Whether [key] reached [maxAttempts].
  Future<bool> tooManyAttempts(
    String key,
    int maxAttempts,
    Duration decay,
  ) async => await attempts(key, decay) >= maxAttempts;

  /// The attempts [key] has left.
  Future<int> remaining(String key, int maxAttempts, Duration decay) async {
    final left = maxAttempts - await attempts(key, decay);
    return left < 0 ? 0 : left;
  }

  /// The time until [key] may try again.
  Future<Duration> availableIn(String key, int maxAttempts, Duration decay) =>
      store.availableIn(key, maxAttempts, decay);

  /// Forgets the attempts of [key] (after a successful login, say).
  Future<void> clear(String key) => store.clear(key);

  /// Forgets every attempt.
  Future<void> flush() => store.flush();
}

/// 429 with `Retry-After` and `X-RateLimit-*` headers.
final class ThrottleRequestsException extends HttpException {
  /// A 429 with the throttle headers.
  const ThrottleRequestsException({
    String message = 'Too Many Attempts.',
    super.headers,
  }) : super(429, message);
}

/// `throttle:60,1` (max attempts, decay minutes) or `throttle:api`
/// (named limiter). Adds `X-RateLimit-Limit`/`X-RateLimit-Remaining` to
/// responses and answers 429 with `Retry-After` when exceeded.
final class ThrottleMiddleware implements RunsBeforeBindings {
  /// [maxAttempts] per [decay], or the limiter named [limiterName].
  const ThrottleMiddleware({
    this.maxAttempts = 60,
    this.decay = const Duration(minutes: 1),
    this.limiterName,
    this.prefix = '',
    this.limiter,
    this.userKeyResolver,
    this.failClosed = false,
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

  /// The attempts allowed per window, without a named limiter.
  final int maxAttempts;

  /// The window, without a named limiter.
  final Duration decay;

  /// The named limiter applied, when there is one.
  final String? limiterName;

  /// Key prefix separating independent throttles sharing a resolver.
  final String prefix;

  /// The limiter counting. Null uses the application's (the [RateLimiter]
  /// of the container: its store and named limiters), or, outside an
  /// application, one in this isolate's memory.
  final RateLimiter? limiter;

  /// Returns the authenticated user's id (or `null` for guests) so limits
  /// follow the user instead of the IP.
  final FutureOr<Object?> Function(Request request)? userKeyResolver;

  /// Whether every limit of this middleware fails closed (as
  /// [Limit.failClosed]): a request the store cannot count gets the 429.
  final bool failClosed;

  @override
  Future<Response> handle(Request request, Next next) async {
    final limiter =
        this.limiter ??
        Container.current.tryMake<RateLimiter>() ??
        _defaultLimiter;
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
      final result = await limiter.attempt(
        key,
        limit.maxAttempts,
        limit.decay,
        algorithm: limit.algorithm,
        failClosed: failClosed || limit.failClosed,
      );
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

  /// The key of a limit without its own: the user's id when
  /// [userKeyResolver] finds one, else the matched route's domain and the
  /// client address, as Laravel's `ThrottleRequests::resolveRequestSignature`
  /// (`$route->getDomain().'|'.$request->ip()`, unhashed here). Never the
  /// request's `Host` header, which the client chooses: one client sending
  /// a different `Host` per request would get a bucket per value. Every
  /// route under one `throttle:` limit and domain shares the client's
  /// bucket, as in Laravel; give a route its own with a named limiter.
  Future<String> _signature(Request request) async {
    final user = await userKeyResolver?.call(request);
    if (user != null) {
      return 'user:$user';
    }
    return '${request.route?.domainPattern?.source ?? ''}|${request.ip}';
  }

  static final RateLimiter _defaultLimiter = RateLimiter();
}
