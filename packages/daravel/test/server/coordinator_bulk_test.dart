import 'dart:async';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A bulk service whose answers wait until the test lets them go: what it
/// received, in order, and how many it holds unanswered.
final class _Held with PrioritizedService implements CoordinatorService {
  final List<Object?> received = [];
  final List<Completer<Object?>> held = [];
  bool hold = true;

  @override
  CoordinatorPriority get priority => CoordinatorPriority.bulk;

  @override
  String get name => 'held';

  @override
  Object? handle(String op, Map<String, Object?> args) {
    received.add(args['n']);
    if (!hold) {
      return args['n'];
    }
    final answer = Completer<Object?>();
    held.add(answer);
    return answer.future.then((_) => args['n']);
  }

  void releaseAll() {
    for (final answer in held) {
      answer.complete();
    }
    held.clear();
  }

  @override
  Map<String, Object?> stats() => const {};
}

/// A bulk service whose calls each take [cost] of the coordinator's time.
final class _SlowBulk with PrioritizedService implements CoordinatorService {
  _SlowBulk(this.cost);

  final Duration cost;
  int served = 0;

  @override
  CoordinatorPriority get priority => CoordinatorPriority.bulk;

  @override
  String get name => 'slowbulk';

  @override
  Object? handle(String op, Map<String, Object?> args) {
    final watch = Stopwatch()..start();
    while (watch.elapsed < cost) {}
    served++;
    return null;
  }

  @override
  Map<String, Object?> stats() => const {};
}

/// A normal service recording the order its calls arrive in.
final class _Ordered implements CoordinatorService {
  final List<Object?> received = [];

  /// Called as each call is served (the coordinator shares the test's
  /// isolate, so its reply would be read only later).
  void Function()? onServed;

  @override
  String get name => 'ordered';

  @override
  Object? handle(String op, Map<String, Object?> args) {
    received.add(args['n']);
    onServed?.call();
    return null;
  }

  @override
  Map<String, Object?> stats() => const {};
}

/// A bulk service recording each worker's calls in the order served.
final class _OrderedBulk with PrioritizedService implements CoordinatorService {
  final Map<Object?, List<int>> byWorker = {};

  @override
  CoordinatorPriority get priority => CoordinatorPriority.bulk;

  @override
  String get name => 'orderedbulk';

  @override
  Object? handle(String op, Map<String, Object?> args) {
    (byWorker[args['w']] ??= []).add(args['n']! as int);
    return null;
  }

  @override
  Map<String, Object?> stats() => const {};
}

/// Counts priority lookups (the healthy path makes few).
final class _Counted with PrioritizedService implements CoordinatorService {
  int lookups = 0;

  @override
  CoordinatorPriority get priority => CoordinatorPriority.critical;

  @override
  String get name => 'counted';

  @override
  CoordinatorPriority priorityFor(String op, Object? args) {
    lookups++;
    return CoordinatorPriority.critical;
  }

  @override
  Object? handle(String op, Map<String, Object?> args) => null;

  @override
  Map<String, Object?> stats() => const {};
}

Future<void> until(bool Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late Coordinator coordinator;
  late _Held held;

  setUp(() {
    coordinator = Coordinator(probeEvery: const Duration(hours: 1));
    held = _Held();
    coordinator.register(held);
  });
  tearDown(() => coordinator.close());

  RemoteCoordinatorChannel channel({int window = 4, int buffer = 1024}) {
    final remote = RemoteCoordinatorChannel(
      coordinator.listen(),
      bulkWindow: window,
      bulkBuffer: buffer,
    );
    addTearDown(remote.close);
    return remote;
  }

  test('at most the window of bulk calls is unanswered; the rest wait, then '
      'go as batches, in order', () async {
    final remote = channel();
    final answers = [
      for (var n = 0; n < 20; n++)
        remote.callBulk('held', 'x', {
          'n': n,
        }, timeout: const Duration(seconds: 5)),
    ];
    await until(() => held.received.length == 4, 'the window');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(held.received, [0, 1, 2, 3], reason: 'no more than the window');
    expect(remote.bulkWaiting, 16);
    held.hold = false;
    held.releaseAll();
    expect(await Future.wait(answers), [for (var n = 0; n < 20; n++) n]);
    expect(held.received, [for (var n = 0; n < 20; n++) n], reason: 'order');
    expect(remote.bulkStats.batches, greaterThan(0), reason: 'grouped');
    expect(remote.bulkInFlight, 0);
  });

  test('a full buffer refuses a new call, or drops the oldest waiting one '
      '(its future fails)', () async {
    final refusing = channel(window: 1, buffer: 2);
    final first = refusing.callBulk('held', 'x', {'n': 0});
    final kept = [
      refusing.callBulk('held', 'x', {'n': 1}),
      refusing.callBulk('held', 'x', {'n': 2}),
    ];
    await expectLater(
      refusing.callBulk('held', 'x', {'n': 3}),
      throwsA(isA<CoordinatorOverloaded>()),
    );

    final dropping = channel(window: 1, buffer: 2);
    final busy = dropping.callBulk('held', 'x', {'n': 10});
    final oldest = dropping.callBulk('held', 'x', {
      'n': 11,
    }, overflow: BulkOverflow.dropOldest);
    final kept2 = [
      dropping.callBulk('held', 'x', {
        'n': 12,
      }, overflow: BulkOverflow.dropOldest),
      dropping.callBulk('held', 'x', {
        'n': 13,
      }, overflow: BulkOverflow.dropOldest),
    ];
    await expectLater(oldest, throwsA(isA<CoordinatorOverloaded>()));
    expect(dropping.bulkStats.dropped, 1);

    held.hold = false;
    held.releaseAll();
    expect(await Future.wait([first, ...kept]), [0, 1, 2]);
    expect(await Future.wait([busy, ...kept2]), [10, 12, 13]);
  });

  test('a call that times out gives its credit back: the next one is sent '
      '(no refill on a timer)', () async {
    final remote = channel(window: 1);
    final stuck = remote.callBulk('held', 'x', {
      'n': 0,
    }, timeout: const Duration(milliseconds: 50));
    final next = remote.callBulk('held', 'x', {
      'n': 1,
    }, timeout: const Duration(seconds: 5));
    await expectLater(stuck, throwsA(isA<CoordinatorTimeoutException>()));
    await until(() => held.received.length == 2, 'the next call sent');
    held.hold = false;
    held.releaseAll();
    expect(await next, 1);
  });

  test('flush waits for the bulk calls waiting and unanswered', () async {
    final remote = channel(window: 1);
    final answers = [
      for (var n = 0; n < 3; n++) remote.callBulk('held', 'x', {'n': n}),
    ];
    var flushed = false;
    final flushing = remote.flush().then((_) => flushed = true);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(flushed, isFalse);
    held.hold = false;
    held.releaseAll();
    await flushing;
    expect(await Future.wait(answers), [0, 1, 2]);
  });

  test('a channel is known to the coordinator from its hello: told of the '
      'health before any call', () async {
    final remote = channel();
    await Future<void>.delayed(const Duration(milliseconds: 20));
    coordinator.observeLag(const Duration(seconds: 1));
    await until(
      () => remote.coordinatorState == CoordinatorState.saturated,
      'the announcement',
    );
  });

  test(
    'a saturated coordinator refuses a batch\'s calls in one reply',
    () async {
      // A batch that crossed the announcement: sent raw, by a worker the
      // coordinator never told (a channel would fail its waiting calls
      // itself on hearing it).
      final port = coordinator.listen();
      final replies = ReceivePort();
      addTearDown(replies.close);
      coordinator.observeLag(const Duration(seconds: 1));
      port.send(
        CoordinatorBatch([
          for (var n = 0; n < 3; n++)
            CoordinatorRequest(
              id: n,
              service: 'held',
              op: 'x',
              args: {'n': n},
              replyTo: replies.sendPort,
            ),
        ], replies.sendPort),
      );
      final reply = await replies.first as CoordinatorBatchReply;
      expect([for (final r in reply.replies) r.id], [0, 1, 2]);
      expect([
        for (final r in reply.replies) r.errorKind,
      ], everyElement(CoordinatorErrorKind.overloaded));
      expect(held.received, isEmpty);
      expect((coordinator.stats()['shed']! as Map)['held'], 3);
    },
  );

  test(
    'while healthy the coordinator works out few calls\' priority',
    () async {
      final counted = _Counted();
      coordinator.register(counted);
      final remote = channel();
      for (var i = 0; i < 64; i++) {
        await remote.call('counted', 'x', const {});
      }
      expect(counted.lookups, 64 ~/ Coordinator.classifyEvery);
      expect(
        (coordinator.stats()['served_by_priority']! as Map)['critical'],
        64,
        reason: 'the sample counts for all',
      );
    },
  );

  group('a busy host is not a queue (§6.6)', () {
    test('a long wait with few messages handled is starvation, not lag', () {
      const waited = Duration(milliseconds: 80);
      expect(Coordinator.lagOf(waited, 0), Duration.zero);
      expect(Coordinator.lagOf(waited, 500), waited);
      expect(
        Coordinator.starvationOf(Duration.zero, waited, 0, Duration.zero),
        waited,
      );
      expect(
        Coordinator.starvationOf(Duration.zero, waited, 500, Duration.zero),
        Duration.zero,
        reason: 'a queue, counted as lag instead',
      );
    });

    test('starvation leaves the coordinator healthy; a queue saturates it', () {
      for (var i = 0; i < 5; i++) {
        coordinator.observeLag(
          Coordinator.lagOf(const Duration(milliseconds: 80), 0),
        );
      }
      expect(coordinator.state, CoordinatorState.healthy);
      coordinator.observeLag(
        Coordinator.lagOf(const Duration(milliseconds: 80), 500),
      );
      expect(coordinator.state, CoordinatorState.saturated);
    });

    test('saturated recovers only after recoverySamples measurements below '
        'it', () {
      coordinator.observeLag(const Duration(seconds: 1));
      expect(coordinator.state, CoordinatorState.saturated);
      for (var i = 0; i < Coordinator.recoverySamples - 1; i++) {
        coordinator.observeLag(Duration.zero);
        expect(coordinator.state, CoordinatorState.saturated);
      }
      coordinator.observeLag(Duration.zero);
      expect(coordinator.state, isNot(CoordinatorState.saturated));
    });
  });

  test('a rate limit is asked while the coordinator says it is saturated '
      '(no short-circuit: it is answered)', () async {
    final remote = channel();
    final store = ProcessRateLimitStore(
      remote,
      timeout: const Duration(seconds: 2),
      leaseThreshold: 1 << 40,
    );
    final limits = createStandardCoordinator();
    addTearDown(limits.close);
    // The standard services on this coordinator too.
    coordinator.register(limits.service(RateLimitService.serviceName)!);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    coordinator.observeLag(const Duration(seconds: 1));
    await until(
      () => remote.coordinatorState == CoordinatorState.saturated,
      'the announcement',
    );
    final results = [
      for (var i = 0; i < 5; i++)
        await store.attempt('k', 3, const Duration(minutes: 1)),
    ];
    expect(results.map((r) => r.allowed), [true, true, true, false, false]);
    expect(results.every((r) => !r.degraded), isTrue);
  });

  test('the announcement names bulk operations, not their services: '
      'subscriptions and the metrics scrape go on while saturated', () async {
    final standard = createStandardCoordinator()
      ..observeLag(const Duration(seconds: 1));
    addTearDown(standard.close);
    final remote = RemoteCoordinatorChannel(standard.listen());
    addTearDown(remote.close);
    await until(
      () => remote.coordinatorState == CoordinatorState.saturated,
      'the announcement',
    );
    expect(remote.shortCircuits('broadcast', 'publish'), isTrue);
    expect(remote.shortCircuits('broadcast', 'subscribe'), isFalse);
    expect(remote.shortCircuits(MetricsService.serviceName, 'publish'), isTrue);
    expect(
      remote.shortCircuits(MetricsService.serviceName, 'collect'),
      isFalse,
    );
    expect(
      await remote.call(MetricsService.serviceName, 'collect', const {}),
      isNotNull,
      reason: 'the scrape is answered',
    );
  });

  test('one worker\'s calls keep their order while the state goes saturated, '
      'lagging and healthy (calls put off are not overtaken)', () async {
    final ordered = _Ordered();
    coordinator.register(ordered);
    final remote = channel();
    final answers = <Future<Object?>>[];
    for (var round = 0; round < 10; round++) {
      coordinator.observeLag(
        round.isEven ? const Duration(seconds: 1) : Duration.zero,
      );
      for (var i = 0; i < 20; i++) {
        answers.add(
          remote.call('ordered', 'x', {
            'n': round * 20 + i,
          }, timeout: const Duration(seconds: 5)),
        );
      }
      // Lets the coordinator take some of them before the state changes.
      await Future<void>.delayed(Duration.zero);
    }
    for (var i = 0; i < Coordinator.recoverySamples + 1; i++) {
      coordinator.observeLag(Duration.zero);
    }
    await Future.wait(answers);
    expect(ordered.received, [for (var n = 0; n < 200; n++) n]);
  });

  test('lagging with only bulk calls put off, a normal call is served '
      'without waiting behind them', () async {
    final slow = _SlowBulk(const Duration(milliseconds: 3));
    final ordered = _Ordered();
    coordinator
      ..register(slow)
      ..register(ordered);
    for (var i = 0; i < 3; i++) {
      coordinator.observeLag(const Duration(milliseconds: 10));
    }
    expect(coordinator.state, CoordinatorState.lagging);
    final channels = [for (var i = 0; i < 10; i++) channel(window: 16)];
    final bulk = [
      for (final c in channels)
        for (var i = 0; i < 16; i++)
          c.callBulk('slowbulk', 'x', {
            'n': i,
          }, timeout: const Duration(seconds: 10)),
    ];
    await until(() => coordinator.deferred > 0, 'bulk calls put off');
    var slowServedThen = -1;
    ordered.onServed = () => slowServedThen = slow.served;
    await channels.first.call('ordered', 'x', {'n': 1});
    await Future.wait(bulk);
    expect(
      slowServedThen,
      lessThan(160),
      reason: 'answered before every bulk call was served',
    );
  });

  test('under bulk traffic that never pauses, the coordinator turns healthy '
      'once the lag is gone, its calls put off still run out, and each '
      "worker's calls keep their order", () async {
    final ordered = _OrderedBulk();
    coordinator.register(ordered);
    for (var i = 0; i < 3; i++) {
      coordinator.observeLag(const Duration(milliseconds: 10));
    }
    expect(coordinator.state, CoordinatorState.lagging);
    var running = true;
    final senders = [
      for (var w = 0; w < 8; w++)
        () async {
          // A full window and more at a time: calls wait in the buffer
          // and go as batches.
          final remote = channel(window: 16);
          var n = 0;
          while (running) {
            await Future.wait([
              for (var i = 0; i < 24; i++)
                remote.callBulk('orderedbulk', 'x', {'w': w, 'n': n++}),
            ]);
          }
        }(),
    ];
    await until(() => coordinator.deferred > 0, 'calls put off');
    for (var i = 0; i < Coordinator.recoverySamples; i++) {
      coordinator.observeLag(Duration.zero);
    }
    expect(
      coordinator.state,
      CoordinatorState.healthy,
      reason: 'not held lagging by the calls put off',
    );
    // Bounded: within a few drain turns, while the traffic goes on.
    await until(() => coordinator.deferred == 0, 'the queue run out');
    running = false;
    await Future.wait(senders);
    expect(ordered.byWorker, hasLength(8));
    for (final MapEntry(key: w, value: ns) in ordered.byWorker.entries) {
      expect(ns, [for (var n = 0; n < ns.length; n++) n], reason: 'worker $w');
    }
  });

  test('the evidence of a queue counts every call of a batch', () async {
    final remote = channel(window: 1);
    final before = coordinator.callsHandled;
    final answers = [
      for (var n = 0; n < 17; n++) remote.callBulk('held', 'x', {'n': n}),
    ];
    held.hold = false;
    held.releaseAll();
    await Future.wait(answers);
    // One alone, then 16 in batches: 17 calls, whatever the messages.
    expect(coordinator.callsHandled - before, 17);
  });

  test('bulk calls waiting for credit fail at once when saturation is '
      'announced, not when sent', () async {
    final remote = channel(window: 1);
    final first = remote.callBulk('held', 'x', {'n': 0});
    final waiting = [
      for (var n = 1; n < 4; n++) remote.callBulk('held', 'x', {'n': n}),
    ];
    await until(() => held.received.isNotEmpty, 'the first call');
    expect(remote.bulkWaiting, 3);
    coordinator.observeLag(const Duration(seconds: 1));
    for (final answer in waiting) {
      await expectLater(answer, throwsA(isA<CoordinatorOverloaded>()));
    }
    expect(remote.bulkWaiting, 0);
    expect(held.received, [0], reason: 'none of them was sent');
    held.releaseAll();
    expect(await first, 0);
  });

  test('a refusal is known by its kind, not its text', () async {
    // A coordinator stand-in that refuses with an unusual text.
    final fake = RawReceivePort();
    addTearDown(fake.close);
    fake.handler = (Object? message) {
      if (message is CoordinatorRequest) {
        message.replyTo.send(
          CoordinatorReply(
            message.id,
            error: 'reworded: try again later',
            errorKind: CoordinatorErrorKind.overloaded,
          ),
        );
      }
    };
    final remote = RemoteCoordinatorChannel(fake.sendPort);
    addTearDown(remote.close);
    await expectLater(
      remote.call('any', 'x', const {}),
      throwsA(isA<CoordinatorOverloaded>()),
    );
  });
}
