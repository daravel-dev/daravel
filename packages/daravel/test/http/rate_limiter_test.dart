import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  final start = DateTime.utc(2026, 10, 24, 12);
  var now = start;
  late RateLimiter limiter;

  setUp(() {
    now = start;
    limiter = RateLimiter(store: MemoryRateLimitStore(clock: () => now));
  });

  test('fixed window (Laravel): blocks after max attempts until the window '
      'started by the first hit resets', () async {
    const decay = Duration(minutes: 1);
    for (var i = 0; i < 3; i++) {
      final result = await limiter.attempt('k', 3, decay);
      expect(result.allowed, isTrue);
      expect(result.remaining, 2 - i);
      now = now.add(const Duration(seconds: 10));
    }
    final blocked = await limiter.attempt('k', 3, decay);
    expect(blocked.allowed, isFalse);
    expect(blocked.remaining, 0);
    expect(blocked.retryAfter, const Duration(seconds: 30));
    expect(await limiter.tooManyAttempts('k', 3, decay), isTrue);
    expect(
      await limiter.availableIn('k', 3, decay),
      const Duration(seconds: 30),
    );
    // The window opened by the first hit (t=0) resets at t=60s.
    now = start.add(const Duration(seconds: 61));
    expect(await limiter.attempts('k', decay), 0);
    final fresh = await limiter.attempt('k', 3, decay);
    expect(fresh.allowed, isTrue);
    expect(fresh.remaining, 2);
    await limiter.clear('k');
    expect(await limiter.attempts('k', decay), 0);
    expect(limiter.store.scope, StateScope.isolate);
  });

  test('named limiters resolve Limit, List<Limit> or null', () async {
    limiter
      ..define('one', (_) => Limit.perMinute(5).by('x'))
      ..define('many', (_) async => [Limit.perSecond(1), Limit.perDay(100)])
      ..define('open', (_) => null);
    final request = Request.fake();
    expect((await limiter.limitsFor('one', request)).single.key, 'x');
    expect(await limiter.limitsFor('many', request), hasLength(2));
    expect(await limiter.limitsFor('open', request), isEmpty);
    expect(() => limiter.limitsFor('missing', request), throwsStateError);
    expect(const Limit.none().isUnlimited, isTrue);
  });

  test(
    'throttle middleware adds headers and answers 429 with Retry-After',
    () async {
      final middleware = ThrottleMiddleware.fromParams([
        '2',
        '1',
      ], limiter: limiter);
      Future<Response> next(Request _) async => Response.text('ok');
      final first = await middleware.handle(Request.fake(path: '/a'), next);
      expect(first.headers['x-ratelimit-limit'], '2');
      expect(first.headers['x-ratelimit-remaining'], '1');
      await middleware.handle(Request.fake(path: '/a'), next);
      // A different path has its own signature.
      expect(
        (await middleware.handle(
          Request.fake(path: '/b'),
          next,
        )).headers['x-ratelimit-remaining'],
        '1',
      );
      now = now.add(const Duration(seconds: 15));
      await expectLater(
        () => middleware.handle(Request.fake(path: '/a'), next),
        throwsA(
          isA<ThrottleRequestsException>()
              .having((e) => e.status, 'status', 429)
              .having((e) => e.headers['retry-after'], 'retry-after', '45')
              .having(
                (e) => e.headers['x-ratelimit-remaining'],
                'remaining',
                '0',
              ),
        ),
      );
    },
  );

  test(
    'named throttle keys by the limit key and supports custom responses',
    () async {
      limiter.define(
        'login',
        (request) => Limit.perMinute(1)
            .by('${request.query['email']}|${request.ip}')
            .response(
              (request, headers) => Response.json(
                {'slow': 'down'},
                status: 429,
                headers: headers,
              ),
            ),
      );
      final middleware = ThrottleMiddleware.fromParams([
        'login',
      ], limiter: limiter);
      Future<Response> next(Request _) async => Response.text('ok');
      final ana = Request.fake(query: {'email': 'ana@x.io'});
      expect((await middleware.handle(ana, next)).status, 200);
      final blocked = await middleware.handle(ana, next);
      expect(blocked.status, 429);
      expect(blocked.headers['retry-after'], '60');
      // Another email from the same IP is independent.
      expect(
        (await middleware.handle(
          Request.fake(query: {'email': 'bo@x.io'}),
          next,
        )).status,
        200,
      );
    },
  );

  test('authenticated users are keyed by id instead of ip', () async {
    final middleware = ThrottleMiddleware(
      maxAttempts: 1,
      limiter: limiter,
      userKeyResolver: (request) => request.headers['x-user'],
    );
    Future<Response> next(Request _) async => Response.text('ok');
    await middleware.handle(
      Request.fake(headers: {'x-user': '7'}, ip: '1.1.1.1'),
      next,
    );
    await expectLater(
      () => middleware.handle(
        Request.fake(headers: {'x-user': '7'}, ip: '2.2.2.2'),
        next,
      ),
      throwsA(isA<ThrottleRequestsException>()),
    );
    expect(
      (await middleware.handle(Request.fake(ip: '1.1.1.1'), next)).status,
      200,
    );
  });
  group('algorithms', () {
    test('a limit keeps its algorithm through by() and response()', () {
      final limit = Limit.perMinute(5)
          .gcra()
          .by('u')
          .response(
            (request, headers) => Response.text('slow down', status: 429),
          );
      expect(limit.algorithm, RateLimitAlgorithm.gcra);
      expect(limit.key, 'u');
      expect(Limit.perMinute(5).algorithm, RateLimitAlgorithm.fixedWindow);
      expect(
        Limit.perMinute(5).slidingWindow().algorithm,
        RateLimitAlgorithm.slidingWindow,
      );
    });

    test('a store without the algorithm counts a fixed window', () async {
      const decay = Duration(minutes: 1);
      final hits = [
        for (var i = 0; i < 3; i++)
          (await limiter.attempt(
            'g',
            2,
            decay,
            algorithm: RateLimitAlgorithm.gcra,
          )).allowed,
      ];
      expect(hits, [true, true, false]);
    });

    test('a store with it is asked, from the middleware too', () async {
      final store = _AlgorithmStore();
      final limiter = RateLimiter(store: store)
        ..define('api', (request) => Limit.perMinute(2).slidingWindow());
      final middleware = ThrottleMiddleware(
        limiterName: 'api',
        limiter: limiter,
      );
      final response = await middleware.handle(
        Request.fake(),
        (request) async => Response.text('ok'),
      );
      expect(response.headers['x-ratelimit-remaining'], '1');
      expect(store.calls, [RateLimitAlgorithm.slidingWindow]);
      await limiter.attempt('k', 2, const Duration(minutes: 1));
      expect(store.calls, hasLength(1)); // a fixed window: attempt()
    });
  });
}

final class _AlgorithmStore implements AlgorithmRateLimitStore {
  final MemoryRateLimitStore _memory = MemoryRateLimitStore();
  final List<RateLimitAlgorithm> calls = [];

  @override
  bool supports(RateLimitAlgorithm algorithm) => true;

  @override
  Future<RateLimitResult> attemptWith(
    RateLimitAlgorithm algorithm,
    String key,
    int maxAttempts,
    Duration decay,
  ) async {
    calls.add(algorithm);
    return RateLimitResult(
      allowed: true,
      limit: maxAttempts,
      remaining: maxAttempts - 1,
      resetAt: DateTime.utc(2030),
    );
  }

  @override
  StateScope get scope => StateScope.isolate;

  @override
  Future<RateLimitResult> attempt(
    String key,
    int maxAttempts,
    Duration decay,
  ) => _memory.attempt(key, maxAttempts, decay);

  @override
  Future<int> attempts(String key, Duration decay) =>
      _memory.attempts(key, decay);

  @override
  Future<Duration> availableIn(String key, int maxAttempts, Duration decay) =>
      _memory.availableIn(key, maxAttempts, decay);

  @override
  Future<void> clear(String key) => _memory.clear(key);

  @override
  Future<void> flush() => _memory.flush();
}
