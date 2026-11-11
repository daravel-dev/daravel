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
      // A port the coordinator did not know is told the state first.
      final reply = await replies.firstWhere(
        (m) => m is CoordinatorBatchReply,
      ) as CoordinatorBatchReply;
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
  group('a refusal decided in the worker arrives on the next turn', () {
    test(
      'a sender retrying at once in a loop still lets a timer fire',
      () async {
        final remote = channel(window: 1, buffer: 1);
        final held1 = remote.callBulk('held', 'x', {'n': 0});
        final held2 = remote.callBulk('held', 'x', {'n': 1});
        await until(() => held.received.isNotEmpty, 'the first call');
        var fired = false;
        Timer(const Duration(milliseconds: 10), () => fired = true);
        final watch = Stopwatch()..start();
        var refused = 0;
        // No other await: before, an already failed future kept this loop in
        // microtasks and the timer never fired.
        while (!fired && watch.elapsed < const Duration(seconds: 2)) {
          try {
            await remote.callBulk('held', 'x', {'n': 2});
          } on CoordinatorOverloaded {
            refused++;
          }
        }
        expect(fired, isTrue, reason: 'the event loop ran ($refused refused)');
        expect(refused, greaterThan(0));
        held.hold = false;
        held.releaseAll();
        await Future.wait([held1, held2]);
      },
    );

    test('two callers in their own zones refused in one turn each get '
        'their error; none hangs', () async {
      final remote = channel(window: 1, buffer: 1);
      final held1 = remote.callBulk('held', 'x', {'n': 0});
      final held2 = remote.callBulk('held', 'x', {'n': 1});
      await until(() => held.received.isNotEmpty, 'the first call');
      final uncaught = <Object>[];
      Future<Object?> inZone() {
        final result = Completer<Object?>();
        runZonedGuarded(() async {
          try {
            await remote.callBulk('held', 'x', {'n': 9});
            result.complete('answered');
          } on CoordinatorOverloaded catch (error) {
            result.complete(error);
          }
        }, (error, _) => uncaught.add(error));
        return result.future;
      }

      // Both refused synchronously within this turn, failed by one timer.
      final first = inZone();
      final second = inZone();
      final outcomes = await Future.wait([first, second])
          .timeout(const Duration(seconds: 5));
      expect(outcomes, everyElement(isA<CoordinatorOverloaded>()));
      expect(uncaught, isEmpty);
      held.hold = false;
      held.releaseAll();
      await Future.wait([held1, held2]);
    });

    test('a refused call fails after the current turn, not at once', () async {
      final remote = channel(window: 1, buffer: 1);
      final held1 = remote.callBulk('held', 'x', {'n': 0});
      final held2 = remote.callBulk('held', 'x', {'n': 1});
      await until(() => held.received.isNotEmpty, 'the first call');
      var failed = false;
      unawaited(
        remote
            .callBulk('held', 'x', {'n': 2})
            .catchError((Object _) => failed = true),
      );
      // Microtasks alone do not deliver it.
      await Future<void>.microtask(() {});
      await Future<void>.microtask(() {});
      expect(failed, isFalse);
      // A turn, or a storm spacing when an earlier test refused just now.
      await until(() => failed, 'the refusal');
      held.hold = false;
      held.releaseAll();
      await Future.wait([held1, held2]);
    });

    test(
      'the oldest call dropped for a new one fails on the next turn',
      () async {
        final remote = channel(window: 1, buffer: 1);
        final held1 = remote.callBulk('held', 'x', {'n': 0});
        await until(() => held.received.isNotEmpty, 'the first call');
        var dropped = false;
        final oldest = remote
            .sendBulk('held', 'x', {'n': 1}, overflow: BulkOverflow.dropOldest)
            .catchError((Object _) {
              dropped = true;
              return null;
            });
        final newest = remote.sendBulk('held', 'x', {
          'n': 2,
        }, overflow: BulkOverflow.dropOldest);
        await Future<void>.microtask(() {});
        expect(dropped, isFalse);
        await oldest;
        expect(dropped, isTrue);
        held.hold = false;
        held.releaseAll();
        await Future.wait([held1, newest]);
      },
    );
    test(
      'an occasional refusal costs one turn, not the storm spacing',
      () async {
        final remote = channel(window: 1, buffer: 1);
        final held1 = remote.callBulk('held', 'x', {'n': 0});
        final held2 = remote.callBulk('held', 'x', {'n': 1});
        await until(() => held.received.isNotEmpty, 'the first call');
        // Quiet: no refusal tick for well over the spacing.
        await Future<void>.delayed(
          RemoteCoordinatorChannel.refusalStormSpacing * 20,
        );
        final before = RemoteCoordinatorChannel.refusalTickCounts;
        await expectLater(
          remote.callBulk('held', 'x', {'n': 2}),
          throwsA(isA<CoordinatorOverloaded>()),
        );
        final after = RemoteCoordinatorChannel.refusalTickCounts;
        expect(after.ticks - before.ticks, 1);
        expect(after.stormTicks - before.stormTicks, 0);
        held.hold = false;
        held.releaseAll();
        await Future.wait([held1, held2]);
      },
    );

    test('a storm: senders retrying at once share one tick per round, each '
        'after the storm spacing', () async {
      final remote = channel(window: 1, buffer: 1);
      final held1 = remote.callBulk('held', 'x', {'n': 0});
      final held2 = remote.callBulk('held', 'x', {'n': 1});
      await until(() => held.received.isNotEmpty, 'the first call');
      const rounds = 20;
      const lanes = 8;
      // The storm is judged on a clock the test holds still: each tick then
      // comes "less than the spacing" after the previous one, as on an idle
      // machine. On the wall clock, a loaded machine (CI) can deschedule
      // the isolate for over a millisecond between two ticks, which the
      // rule rightly counts as no storm (seen: 18 storm ticks of 20).
      RemoteCoordinatorChannel.refusalClockForTesting = () => 0;
      addTearDown(() => RemoteCoordinatorChannel.refusalClockForTesting = null);
      final before = RemoteCoordinatorChannel.refusalTickCounts;
      Future<void> lane() async {
        for (var i = 0; i < rounds; i++) {
          try {
            await remote.callBulk('held', 'x', {'n': 2});
          } on CoordinatorOverloaded {
            // Retried at once.
          }
        }
      }

      await Future.wait([for (var i = 0; i < lanes; i++) lane()]);
      final after = RemoteCoordinatorChannel.refusalTickCounts;
      final ticks = after.ticks - before.ticks;
      // Derived from the rule, not from a run: the lanes start in one turn,
      // so their first refusals share one tick. A tick fails all of them,
      // and each lane's next call runs in the microtasks of that tick's
      // timer, so the next refusals again share one tick: one tick per
      // round, `rounds` in all, not one per refusal (`rounds * lanes`).
      // One more is allowed for a lane whose first call was not refused in
      // the first turn. The counts are differences taken in this test, so
      // other tests and the order of files do not matter.
      expect(ticks, lessThanOrEqualTo(rounds + 1));
      // Every tick after the first follows the previous one at once.
      expect(
        after.stormTicks - before.stormTicks,
        greaterThanOrEqualTo(ticks - 1),
      );
      held.hold = false;
      held.releaseAll();
      await Future.wait([held1, held2]);
    });
  });
  group('Review #153', () {
    test('a worker no longer told of the state stops believing saturated '
        'after staleHealthAfter', () async {
      final remote = channel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      coordinator.observeLag(const Duration(seconds: 1));
      await until(
        () => remote.coordinatorState == CoordinatorState.saturated,
        'the announcement',
      );
      expect(remote.shortCircuits('held', 'x'), isTrue);
      final states = <CoordinatorState>[];
      remote.onStateChange = states.add;
      // No announcement for longer than the limit (the coordinator forgot
      // this worker, or the message was lost).
      remote.ageLastHealth(
        RemoteCoordinatorChannel.staleHealthAfter + const Duration(seconds: 1),
      );
      expect(remote.shortCircuits('held', 'x'), isFalse);
      expect(remote.coordinatorState, CoordinatorState.healthy);
      expect(states, [CoordinatorState.healthy]);
    });

    test('past maxPeers only the oldest peer is forgotten; a live worker '
        'forgotten is learnt again from its next call', () async {
      final first = channel();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final port = coordinator.listen();
      final ports = <RawReceivePort>[];
      addTearDown(() {
        for (final p in ports) {
          p.close();
        }
      });
      for (var i = 0; i < Coordinator.maxPeers; i++) {
        final p = RawReceivePort((Object? _) {});
        ports.add(p);
        port.send(CoordinatorHello(p.sendPort));
      }
      await until(
        () => coordinator.peerCount == Coordinator.maxPeers,
        'the hellos',
      );
      // Not cleared: still maxPeers, the first (oldest) forgotten.
      coordinator.observeLag(const Duration(seconds: 1));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(coordinator.peerCount, Coordinator.maxPeers);
      expect(first.coordinatorState, CoordinatorState.healthy);
      // Its next call while saturated: learnt again and told.
      await first
          .call('unknown', 'x', const {})
          .then<Object?>((value) => value, onError: (Object _) => null);
      await until(
        () => first.coordinatorState == CoordinatorState.saturated,
        'the announcement to the forgotten worker',
      );
    });

    test('a named worker restarted replaces its port; forgetWorker forgets '
        'it', () async {
      final port = coordinator.listen();
      final a = RawReceivePort((Object? _) {});
      final b = RawReceivePort((Object? _) {});
      addTearDown(a.close);
      addTearDown(b.close);
      port
        ..send(CoordinatorHello(a.sendPort, 'daravel-worker-1'))
        ..send(CoordinatorHello(b.sendPort, 'daravel-worker-1'));
      await until(() => coordinator.peerCount == 1, 'one peer');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(coordinator.peerCount, 1);
      coordinator.forgetWorker('daravel-worker-1');
      expect(coordinator.peerCount, 0);
    });

    test('a critical call inside a batch is served while saturated', () async {
      coordinator.register(_Counted());
      final port = coordinator.listen();
      final replies = ReceivePort();
      addTearDown(replies.close);
      coordinator.observeLag(const Duration(seconds: 1));
      port.send(
        CoordinatorBatch([
          CoordinatorRequest(
            id: 1,
            service: 'counted',
            op: 'x',
            args: const <String, Object?>{},
            replyTo: replies.sendPort,
          ),
          CoordinatorRequest(
            id: 2,
            service: 'held',
            op: 'x',
            args: const {'n': 0},
            replyTo: replies.sendPort,
          ),
        ], replies.sendPort),
      );
      final received = <CoordinatorReply>[];
      final done = Completer<void>();
      final sub = replies.listen((Object? m) {
        switch (m) {
          case final CoordinatorBatchReply batch:
            received.addAll(batch.replies);
          case final CoordinatorReply reply:
            received.add(reply);
        }
        if (received.length == 2 && !done.isCompleted) {
          done.complete();
        }
      });
      addTearDown(sub.cancel);
      await done.future.timeout(const Duration(seconds: 5));
      final byId = {for (final r in received) r.id: r};
      expect(byId[1]!.error, isNull);
      expect(byId[1]!.errorKind, CoordinatorErrorKind.none);
      expect(byId[2]!.errorKind, CoordinatorErrorKind.overloaded);
    });

    test('a waiting bulk call times out at its own deadline, not behind the '
        'head of the queue', () async {
      final remote = channel(window: 1);
      final inFlight = remote.callBulk('held', 'x', {'n': 0});
      await until(() => held.received.isNotEmpty, 'the first call');
      final slow = remote.callBulk('held', 'x', {
        'n': 1,
      }, timeout: const Duration(seconds: 30));
      var shortFailed = false;
      unawaited(
        remote
            .callBulk('held', 'x', {
              'n': 2,
            }, timeout: const Duration(milliseconds: 100))
            .then<void>((_) {}, onError: (Object _) => shortFailed = true),
      );
      await until(() => shortFailed, 'the short call to time out');
      expect(remote.bulkWaiting, 1, reason: 'the long one still waits');
      held.hold = false;
      held.releaseAll();
      await Future.wait([inFlight, slow]);
    });

    test('bulk calls a full buffer drops are counted on /metrics', () async {
      final remote = channel(window: 1, buffer: 1);
      final metrics = AppMetrics(MetricsRegistry(), channel: remote);
      Future<Object?> quiet(Future<Object?> call) =>
          call.then<Object?>((value) => value, onError: (Object _) => null);
      final inFlight = remote.callBulk('held', 'x', {'n': 0});
      await until(() => held.received.isNotEmpty, 'the first call');
      final calls = <Future<Object?>>[
        for (var n = 1; n < 5; n++)
          quiet(
            remote.sendBulk('held', 'x', {
              'n': n,
            }, overflow: BulkOverflow.dropOldest),
          ),
        quiet(remote.sendBulk('held', 'x', {'n': 9})),
      ];
      final text = metrics.registry.render();
      expect(
        text,
        contains(
          'coordinator_bulk_dropped_total{overflow="dropOldest",'
          'service="held"} 3',
        ),
      );
      expect(
        text,
        contains(
          'coordinator_bulk_dropped_total{overflow="refuse",service="held"} 1',
        ),
      );
      expect(text, contains('coordinator_bulk_waiting 1'));
      expect(text, contains('coordinator_bulk_in_flight 1'));
      held.hold = false;
      held.releaseAll();
      await Future.wait([inFlight, ...calls]);
    });
  });
}
