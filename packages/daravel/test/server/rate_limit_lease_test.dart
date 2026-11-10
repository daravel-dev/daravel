import 'dart:async';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Waits until [condition] holds (polling), failing after [within]. The
/// assertions do not depend on how long anything takes, only on it
/// eventually happening.
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

/// A remote-looking channel whose `acquire` answers are held until the
/// test lets them go: the coordinator has granted the lease, the worker
/// has not heard of it yet.
final class _LateGrantChannel implements CoordinatorChannel {
  _LateGrantChannel(this.coordinator);

  final Coordinator coordinator;
  final List<Completer<void>> held = [];

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
    if (op == 'acquire') {
      final gate = Completer<void>();
      held.add(gate);
      await gate.future;
    }
    return result;
  }
}

void main() {
  const decay = Duration(minutes: 1);
  late Coordinator coordinator;
  late MemoryRateLimitStore counters;

  setUp(() {
    coordinator = createStandardCoordinator();
    counters =
        (coordinator.service(RateLimitService.serviceName)! as RateLimitService)
            .store;
  });
  tearDown(() => coordinator.close());

  test('concurrent attempts on one key are served exactly to the limit '
      'with few coordinator calls', () async {
    final channel = RemoteCoordinatorChannel(coordinator.listen());
    addTearDown(channel.close);
    // A lease TTL and an answer timeout no CI hiccup reaches: nothing is
    // given back mid-test, and no attempt fails open (`degraded`) because a
    // loaded runner answered after the default 50 ms. The fail-open path has
    // its own tests (coordinator_failure_test, rate_limit_fail_closed_test).
    final store = ProcessRateLimitStore(
      channel,
      leaseTtl: const Duration(minutes: 1),
      timeout: const Duration(seconds: 10),
    );
    final before = coordinator.stats()['handled']! as int;
    var allowed = 0;
    var refused = 0;
    while (refused == 0) {
      // 32 keep-alive connections of one proxy hitting one worker.
      final round = await Future.wait([
        for (var i = 0; i < 32; i++) store.attempt('hot', 1000, decay),
      ]);
      for (final result in round) {
        expect(result.degraded, isFalse);
        result.allowed ? allowed++ : refused++;
      }
    }
    expect(allowed, 1000);
    expect(counters.attemptsSync('hot', decay), 1000);
    final calls = (coordinator.stats()['handled']! as int) - before;
    expect(calls, lessThanOrEqualTo(1000 ~/ 8), reason: '$calls calls');
  });

  test('a worker that goes quiet gives its leased hits back', () async {
    final a = RemoteCoordinatorChannel(coordinator.listen());
    final b = RemoteCoordinatorChannel(coordinator.listen());
    addTearDown(a.close);
    addTearDown(b.close);
    const ttl = Duration(milliseconds: 30);
    final workerA = ProcessRateLimitStore(a, leaseTtl: ttl);
    final workerB = ProcessRateLimitStore(b, leaseTtl: ttl);
    for (var i = 0; i < 16; i++) {
      expect((await workerA.attempt('k', 60, decay)).allowed, isTrue);
    }
    // Batches of 1, 2, 4 and 8, then a lease of 16 with 15 left: worker A
    // never asks for this key again, yet the timer gives them back.
    await eventually(() => counters.attemptsSync('k', decay) == 16);
    var allowed = 0;
    while ((await workerB.attempt('k', 60, decay)).allowed) {
      allowed++;
    }
    expect(allowed, 44);
    await eventually(() => counters.attemptsSync('k', decay) == 60);
  });

  test(
    'a lease granted after the timeout goes back to the coordinator',
    () async {
      final channel = _LateGrantChannel(coordinator);
      final errors = <Object>[];
      final store = ProcessRateLimitStore(
        channel,
        timeout: const Duration(milliseconds: 20),
        onError: errors.add,
      );
      final result = await store.attempt('k', 100, decay);
      expect(result.allowed, isTrue);
      expect(result.degraded, isTrue);
      expect(errors.single, isA<CoordinatorTimeoutException>());
      // Granted at the coordinator, unknown to the worker.
      expect(counters.attemptsSync('k', decay), 1);
      for (final gate in channel.held) {
        gate.complete();
      }
      await eventually(() => counters.attemptsSync('k', decay) == 0);
    },
  );

  test('attempts waiting on a failed lease request all fail open', () async {
    final channel = _LateGrantChannel(coordinator);
    final errors = <Object>[];
    final store = ProcessRateLimitStore(
      channel,
      timeout: const Duration(milliseconds: 20),
      onError: errors.add,
    );
    final results = await Future.wait([
      for (var i = 0; i < 8; i++) store.attempt('k', 100, decay),
    ]);
    expect(results.every((r) => r.allowed && r.degraded), isTrue);
    expect(errors, hasLength(8));
    // One request in flight for the eight of them.
    expect(channel.held, hasLength(1));
    channel.held.single.complete();
    await eventually(() => counters.attemptsSync('k', decay) == 0);
  });
}
