import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Waits until [condition] holds (polling), failing after [within].
Future<void> eventually(
  FutureOr<bool> Function() condition, {
  Duration within = const Duration(seconds: 10),
}) async {
  final watch = Stopwatch()..start();
  while (!await condition()) {
    if (watch.elapsed > within) {
      fail('Condition not met within $within.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// A remote-looking channel whose next [lostAcquires] lock acquisitions are
/// handled by the coordinator but answered with a timeout, as when the
/// reply comes after the worker gave up on it.
final class _LostAckChannel implements CoordinatorChannel {
  _LostAckChannel(this.coordinator);

  final Coordinator coordinator;
  int lostAcquires = 1;

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
  }) async {
    final result = await coordinator.handle(service, op, args);
    if (op == 'acquireLock' && lostAcquires > 0) {
      lostAcquires--;
      throw CoordinatorTimeoutException(service, timeout);
    }
    return result;
  }
}

/// A cache store whose backend is down: every call fails.
final class _DownStore implements CacheStore {
  @override
  StateScope get scope => StateScope.cluster;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      Future<Never>.error(const SocketException('Connection refused'));
}

void main() {
  group('a lock acquisition whose answer is lost', () {
    late Coordinator coordinator;
    setUp(() => coordinator = createStandardCoordinator());
    tearDown(() => coordinator.close());

    test('is released at once instead of held until its TTL', () async {
      final store = ProcessStore(_LostAckChannel(coordinator));
      await expectLater(
        store.acquireLock('order:1', 'request-a', const Duration(minutes: 1)),
        throwsA(isA<CoordinatorTimeoutException>()),
      );
      final locks = ProcessStore(LocalCoordinatorChannel(coordinator));
      await eventually(() async => await locks.lockOwner('order:1') == null);
      expect(
        await locks.acquireLock(
          'order:1',
          'request-b',
          const Duration(minutes: 1),
        ),
        isTrue,
      );
    });

    test('counts as not acquired in Lock.block, which tries again', () async {
      final store = ProcessStore(_LostAckChannel(coordinator));
      final lock = Lock(store, 'report', ttl: const Duration(minutes: 1));
      final ran = await lock.block(
        const Duration(seconds: 10),
        () => 'ran',
        interval: const Duration(milliseconds: 1),
      );
      expect(ran, 'ran');
      expect(await lock.currentOwner(), isNull, reason: 'released after');
    });

    test('a release does not take a lock someone else holds', () async {
      final locks = ProcessStore(LocalCoordinatorChannel(coordinator));
      expect(
        await locks.acquireLock('busy', 'holder', const Duration(minutes: 1)),
        isTrue,
      );
      final store = ProcessStore(_LostAckChannel(coordinator));
      await expectLater(
        store.acquireLock('busy', 'other', const Duration(minutes: 1)),
        throwsA(isA<CoordinatorTimeoutException>()),
      );
      // Let the release go through, then check the holder kept the lock.
      await locks.lockOwner('busy');
      await Future<void>.delayed(Duration.zero);
      expect(await locks.lockOwner('busy'), 'holder');
    });
  });

  group('CacheRateLimitStore with a cache store that fails', () {
    const decay = Duration(minutes: 1);

    test('fails open, degraded, and reports the error', () async {
      final errors = <Object>[];
      final store = CacheRateLimitStore(_DownStore.new, onError: errors.add);
      final result = await store.attempt('k', 5, decay);
      expect(result.allowed, isTrue);
      expect(result.degraded, isTrue);
      expect(errors.single, isA<SocketException>());
      final sliding = await store.attemptWith(
        RateLimitAlgorithm.slidingWindow,
        'k',
        5,
        decay,
      );
      expect(sliding.allowed && sliding.degraded, isTrue);
    });

    test('fails closed when the store or the limit says so', () async {
      final closed = CacheRateLimitStore(_DownStore.new, failClosed: true);
      final refused = await closed.attempt('k', 5, decay);
      expect(refused.allowed, isFalse);
      expect(refused.degraded, isTrue);
      expect(refused.retryAfter, ProcessRateLimitStore.failClosedRetryAfter);

      final limiter = RateLimiter(store: CacheRateLimitStore(_DownStore.new));
      final result = await limiter.attempt('k', 5, decay, failClosed: true);
      expect(result.allowed, isFalse);
    });

    test('a throttled route answers instead of failing with a 500', () async {
      final middleware = ThrottleMiddleware(
        maxAttempts: 5,
        limiter: RateLimiter(store: CacheRateLimitStore(_DownStore.new)),
      );
      final response = await middleware.handle(
        Request.fake(),
        (_) async => Response.text('ok'),
      );
      expect(response.status, 200);
    });
  });

  test('ThrottledReporter reports at most once per interval', () {
    var now = Duration.zero;
    final reports = <(Object, int)>[];
    final reporter = ThrottledReporter(
      (error, skipped) => reports.add((error, skipped)),
      elapsed: () => now,
    );
    for (var i = 0; i < 1000; i++) {
      reporter('timeout $i');
      now += const Duration(microseconds: 900);
    }
    // 1000 failures over 0.9 s: one warning.
    expect(reports, [('timeout 0', 0)]);
    now += const Duration(seconds: 1);
    reporter('later');
    expect(reports.last, ('later', 999));
  });

  group('the process store near cache', () {
    late Coordinator coordinator;
    setUp(() => coordinator = createStandardCoordinator());
    tearDown(() => coordinator.close());

    test('does not keep a value it wrote past the value TTL', () async {
      final store = ProcessStore(
        LocalCoordinatorChannel(coordinator),
        l1Ttl: const Duration(hours: 1),
      );
      await store.put('k', 'v', ttl: const Duration(milliseconds: 20));
      await eventually(() async => await store.get('k') == null);
      await store.putMany({'a': 1}, ttl: const Duration(milliseconds: 20));
      await eventually(() async => (await store.many(['a']))['a'] == null);
    });

    test('does not keep a value it read past the value TTL', () async {
      final writer = ProcessStore(LocalCoordinatorChannel(coordinator));
      final reader = ProcessStore(
        LocalCoordinatorChannel(coordinator),
        l1Ttl: const Duration(hours: 1),
      );
      await writer.put('k', 'v', ttl: const Duration(milliseconds: 20));
      await writer.put('m', 'w', ttl: const Duration(milliseconds: 20));
      // Read once while live (unless the runner was slower than the TTL).
      await reader.get('k');
      await reader.many(['m']);
      await eventually(() async => await reader.get('k') == null);
      await eventually(() async => (await reader.many(['m']))['m'] == null);
      // A value without a TTL is still kept for l1Ttl.
      await writer.put('forever', 'x');
      expect(await reader.get('forever'), 'x');
      await writer.put('forever', 'y');
      expect(await reader.get('forever'), 'x', reason: 'served from L1');
    });
  });
}
