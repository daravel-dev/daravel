import 'dart:async';

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
      final remote = channel(window: 1);
      final first = remote.callBulk('held', 'x', {'n': 0});
      final batch = [
        for (var n = 1; n < 4; n++) remote.callBulk('held', 'x', {'n': n}),
      ];
      await until(() => held.received.isNotEmpty, 'the first call');
      // Saturated after the first was received: the batch the credit of its
      // answer sends is refused, but the channel hears it only when told.
      coordinator.observeLag(const Duration(seconds: 1));
      held.releaseAll();
      expect(await first, 0);
      for (final answer in batch) {
        await expectLater(answer, throwsA(isA<CoordinatorOverloaded>()));
      }
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
}
