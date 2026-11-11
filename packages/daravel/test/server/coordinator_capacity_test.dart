import 'dart:async';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Blocks this isolate's event loop for [duration], as a stalled
/// coordinator does: messages sent before it wait behind it.
void stall(Duration duration) {
  final watch = Stopwatch()..start();
  while (watch.elapsed < duration) {}
}

/// Waits until [condition] holds (polling), failing after [within].
Future<void> eventually(
  bool Function() condition, {
  Duration within = const Duration(seconds: 10),
}) async {
  final watch = Stopwatch()..start();
  while (!condition()) {
    if (watch.elapsed > within) {
      fail('Condition not met within $within.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  const decay = Duration(minutes: 1);
  late Coordinator coordinator;
  late RemoteCoordinatorChannel channel;
  late MemoryRateLimitStore counters;

  setUp(() {
    coordinator = createStandardCoordinator();
    channel = RemoteCoordinatorChannel(coordinator.listen());
    counters =
        (coordinator.service(RateLimitService.serviceName)! as RateLimitService)
            .store;
  });
  tearDown(() {
    channel.close();
    coordinator.close();
  });

  test('a stalled coordinator drops what its callers gave up on', () async {
    final attempt = channel.callTyped(
      RateLimitService.serviceName,
      const RateLimitMessage('attempt', 'k', max: 5, decayMs: 60000),
      timeout: const Duration(milliseconds: 20),
    );
    final lock = channel.callTyped(
      ProcessCacheService.serviceName,
      const LockMessage('acquireLock', 'L', owner: 'me', ttlMs: 60000),
      timeout: const Duration(milliseconds: 20),
    );
    // The coordinator (this isolate) cannot read either message before
    // both deadlines have passed.
    stall(const Duration(milliseconds: 60));
    await expectLater(attempt, throwsA(isA<CoordinatorTimeoutException>()));
    await expectLater(lock, throwsA(isA<CoordinatorTimeoutException>()));
    expect(coordinator.stats()['expired'], 2);
    expect(counters.attemptsSync('k', decay), 0, reason: 'not counted');
    final locks = ProcessStore(LocalCoordinatorChannel(coordinator));
    expect(await locks.lockOwner('L'), isNull, reason: 'not taken');

    final metrics = MetricsRegistry.renderSnapshot(
      MetricsService.coordinatorSnapshot(coordinator.stats()),
    );
    expect(metrics, contains('coordinator_expired_total 2'));
  });

  test('releases are handled however late they arrive', () async {
    final grant = counters.acquireSync('k', 100, decay, 3);
    final release = channel.callTyped(
      RateLimitService.serviceName,
      RateLimitMessage('release', 'k', count: 3, resetAt: grant.resetAtMs),
      timeout: const Duration(milliseconds: 20),
    )..ignore();
    // The coordinator reads the release 60 ms after it was sent, 40 ms past
    // its deadline.
    stall(const Duration(milliseconds: 60));
    // The caller's own outcome depends on which comes first after the
    // stall, its timeout timer or the coordinator's answer: the VM posts the
    // timer's wake-up from another thread, late on a loaded machine, so
    // either is right (#194). What this test is about is the coordinator.
    try {
      await release;
    } on CoordinatorTimeoutException {
      // The timer came first.
    }
    await eventually(() => counters.attemptsSync('k', decay) == 0);
    expect(coordinator.stats()['expired'], 0, reason: 'never dropped');
  });

  test('calls answered in time are not affected', () async {
    final store = ProcessRateLimitStore(channel);
    for (var i = 0; i < 5; i++) {
      expect((await store.attempt('login', 5, decay)).allowed, isTrue);
    }
    expect((await store.attempt('login', 5, decay)).allowed, isFalse);
    expect(coordinator.stats()['expired'], 0);
  });

  test('a stalled event loop with no queue is starvation, not lag '
      '(§6.6)', () async {
    expect(coordinator.stats()['starved_peak_ms'], 0);
    // Longer than the probe interval: the probe fires late by at least the
    // difference, with nothing queued behind it.
    stall(Coordinator.lagProbeInterval * 3);
    await eventually(
      () => (coordinator.stats()['starved_peak_ms']! as num) >= 100,
    );
    expect(coordinator.stats()['queue_lag_peak_ms'], 0);
    expect(coordinator.state, CoordinatorState.healthy);
    final metrics = MetricsRegistry.renderSnapshot(
      MetricsService.coordinatorSnapshot(coordinator.stats()),
    );
    expect(metrics, contains('coordinator_starved_peak_seconds'));
    expect(metrics, contains('coordinator_queue_lag_peak_seconds'));
  });
}
