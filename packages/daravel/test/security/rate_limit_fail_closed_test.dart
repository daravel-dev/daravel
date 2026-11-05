@Tags(['security'])
library;

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Rate limiting fails open by default (ADR-003): when the coordinator
/// cannot count an attempt (an error or a timeout, which flooding requests
/// can cause), the request goes through. A limit guarding credentials can
/// fail closed instead, so overloading the coordinator does not lift it.
void main() {
  const decay = Duration(minutes: 1);

  group('ProcessRateLimitStore when the coordinator times out', () {
    test('fails open by default, marked degraded, reported', () async {
      final errors = <Object>[];
      final store = ProcessRateLimitStore(
        _TimingOutChannel(),
        onError: errors.add,
      );
      final result = await store.attempt('login', 5, decay);
      expect(result.allowed, isTrue);
      expect(result.degraded, isTrue);
      expect(errors.single, isA<CoordinatorTimeoutException>());
    });

    test('refuses with failClosed, with a short Retry-After', () async {
      final errors = <Object>[];
      final store = ProcessRateLimitStore(
        _TimingOutChannel(),
        onError: errors.add,
        failClosed: true,
      );
      final result = await store.attempt('login', 5, decay);
      expect(result.allowed, isFalse);
      expect(result.degraded, isTrue);
      expect(result.remaining, 0);
      expect(result.retryAfter, ProcessRateLimitStore.failClosedRetryAfter);
      expect(errors.single, isA<CoordinatorTimeoutException>());
    });

    test('a leased key (generous limit) fails the same way', () async {
      final open = ProcessRateLimitStore(_TimingOutChannel());
      final closed = ProcessRateLimitStore(
        _TimingOutChannel(),
        failClosed: true,
      );
      // At or above leaseThreshold on a remote channel: the lease path.
      expect((await open.attempt('api', 1000, decay)).allowed, isTrue);
      expect((await closed.attempt('api', 1000, decay)).allowed, isFalse);
    });
  });

  group('RateLimiter.attempt(failClosed:)', () {
    test('refuses what a fail-open store let through uncounted', () async {
      final limiter = RateLimiter(
        store: ProcessRateLimitStore(_TimingOutChannel()),
      );
      expect((await limiter.attempt('k', 5, decay)).allowed, isTrue);
      final refused = await limiter.attempt('k', 5, decay, failClosed: true);
      expect(refused.allowed, isFalse);
      expect(refused.degraded, isTrue);
    });

    test('changes nothing while the store counts', () async {
      final limiter = RateLimiter(store: MemoryRateLimitStore());
      for (var i = 0; i < 2; i++) {
        final result = await limiter.attempt('k', 2, decay, failClosed: true);
        expect(result.allowed, isTrue);
        expect(result.degraded, isFalse);
      }
      final blocked = await limiter.attempt('k', 2, decay, failClosed: true);
      expect(blocked.allowed, isFalse);
      expect(blocked.degraded, isFalse);
    });
  });

  group('ThrottleMiddleware', () {
    RateLimiter limiter() =>
        RateLimiter(store: ProcessRateLimitStore(_TimingOutChannel()))
          ..define('open', (request) => Limit.perMinute(5).by('a'))
          ..define(
            'login',
            (request) => Limit.perMinute(5).by('a').failsClosed(),
          );

    Future<Response> send(ThrottleMiddleware middleware) => middleware.handle(
      Request.fake(ip: '10.0.0.1'),
      (request) async => Response.noContent(),
    );

    test('a limit that fails open lets the request through', () async {
      final response = await send(
        ThrottleMiddleware(limiterName: 'open', limiter: limiter()),
      );
      expect(response.status, 204);
    });

    test('a limit that fails closed answers 429 with Retry-After', () async {
      await expectLater(
        send(ThrottleMiddleware(limiterName: 'login', limiter: limiter())),
        throwsA(
          isA<ThrottleRequestsException>()
              .having((e) => e.status, 'status', 429)
              .having((e) => e.headers['retry-after'], 'retry-after', '1'),
        ),
      );
    });

    test('failClosed on the middleware covers its own limit', () async {
      await expectLater(
        send(ThrottleMiddleware(limiter: limiter(), failClosed: true)),
        throwsA(isA<ThrottleRequestsException>()),
      );
      expect((await send(ThrottleMiddleware(limiter: limiter()))).status, 204);
    });
  });

  test('by, response, slidingWindow and gcra keep failClosed', () {
    final limit = Limit.perMinute(5).failsClosed();
    expect(limit.failClosed, isTrue);
    expect(limit.by('x').failClosed, isTrue);
    expect(limit.response((r, h) => Response.noContent()).failClosed, isTrue);
    expect(limit.slidingWindow().failClosed, isTrue);
    expect(limit.gcra().failClosed, isTrue);
    expect(Limit.perMinute(5).failClosed, isFalse);
    expect(const Limit.none().failClosed, isFalse);
  });
}

/// A coordinator channel whose every call times out.
final class _TimingOutChannel implements CoordinatorChannel {
  @override
  StateScope get scope => StateScope.process;

  @override
  bool get isRemote => true;

  @override
  Future<Object?> call(
    String service,
    String op,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 1),
  }) => Future<Object?>.error(CoordinatorTimeoutException(service, timeout));
}
