import 'dart:async';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class _SlowService implements CoordinatorService {
  @override
  String get name => 'slow';

  @override
  Future<Object?> handle(String op, Map<String, Object?> args) =>
      Future<Object?>.delayed(const Duration(milliseconds: 300), () => op);

  @override
  Map<String, Object?> stats() => const {};
}

void main() {
  late Coordinator coordinator;

  setUp(
    () => coordinator = createStandardCoordinator()..register(_SlowService()),
  );
  tearDown(() => coordinator.close());

  test('local channel dispatches directly and reports stats', () async {
    final channel = LocalCoordinatorChannel(coordinator);
    expect(channel.isRemote, isFalse);
    expect(channel.scope, StateScope.process);
    final store = ProcessRateLimitStore(channel);
    expect(
      (await store.attempt('k', 2, const Duration(minutes: 1))).remaining,
      1,
    );
    expect(
      (await store.attempt('k', 2, const Duration(minutes: 1))).remaining,
      0,
    );
    expect(
      (await store.attempt('k', 2, const Duration(minutes: 1))).allowed,
      isFalse,
    );
    expect(await store.attempts('k', const Duration(minutes: 1)), 2);
    final stats = coordinator.stats();
    expect(stats['handled'], 4);
    expect((stats['services'] as Map)['rateLimiter'], {'keys': 1});
    expect(
      () => channel.call('nope', 'x', const {}),
      throwsA(isA<CoordinatorException>()),
    );
  });

  test(
    'remote channel round-trips over SendPort with correlation ids',
    () async {
      final channel = RemoteCoordinatorChannel(coordinator.listen());
      addTearDown(channel.close);
      expect(channel.isRemote, isTrue);
      final store = ProcessStore(channel);
      await store.put('a', {'n': 1}, ttl: const Duration(minutes: 1));
      expect(await store.get('a'), {'n': 1});
      expect(await store.add('a', 2), isFalse);
      expect(await store.increment('counter', 5), 5);
      expect(await store.increment('counter'), 6);
      expect(await store.many(['a', 'counter', 'none']), {
        'a': {'n': 1},
        'counter': 6,
        'none': null,
      });
      // Concurrent calls keep their own replies.
      final results = await Future.wait([
        for (var i = 0; i < 20; i++) store.increment('parallel'),
      ]);
      expect(results.toSet(), {for (var i = 1; i <= 20; i++) i});
      expect(await store.forget('a'), isTrue);
      expect(await store.get('a'), isNull);
      expect(channel.pending, 0);

      expect(
        await store.acquireLock('L', 'me', const Duration(seconds: 5)),
        isTrue,
      );
      expect(
        await store.acquireLock('L', 'you', const Duration(seconds: 5)),
        isFalse,
      );
      expect(await store.lockOwner('L'), 'me');
      expect(await store.releaseLock('L', 'you'), isFalse);
      expect(await store.releaseLock('L', 'me'), isTrue);
      expect(await store.lockOwner('L'), isNull);

      await expectLater(
        () => channel.call('missing', 'op', const {}),
        throwsA(isA<CoordinatorException>()),
      );
    },
  );

  test('timeouts: rate limiter fails open, locks fail closed', () async {
    final channel = RemoteCoordinatorChannel(coordinator.listen());
    addTearDown(channel.close);
    await expectLater(
      () => channel.call(
        'slow',
        'op',
        const {},
        timeout: const Duration(milliseconds: 50),
      ),
      throwsA(isA<CoordinatorTimeoutException>()),
    );
    expect(
      await channel.call(
        'slow',
        'op',
        const {},
        timeout: const Duration(seconds: 2),
      ),
      'op',
    );

    final errors = <Object>[];
    final limiter = ProcessRateLimitStore(
      _TimingOutChannel(),
      onError: errors.add,
    );
    final result = await limiter.attempt('k', 3, const Duration(minutes: 1));
    expect(result.allowed, isTrue);
    expect(errors.single, isA<CoordinatorTimeoutException>());

    final locks = ProcessStore(_TimingOutChannel());
    await expectLater(
      () => locks.acquireLock('x', 'me', const Duration(seconds: 1)),
      throwsA(isA<CoordinatorTimeoutException>()),
    );
  });

  test('backpressure rejects requests above maxQueue', () async {
    final tiny = Coordinator(maxQueue: 1)..register(_SlowService());
    addTearDown(tiny.close);
    final channel = RemoteCoordinatorChannel(tiny.listen());
    addTearDown(channel.close);
    final first = channel.call(
      'slow',
      'a',
      const {},
      timeout: const Duration(seconds: 2),
    );
    final second = channel.call(
      'slow',
      'b',
      const {},
      timeout: const Duration(seconds: 2),
    )..ignore();
    expect(await first, 'a');
    await expectLater(second, throwsA(isA<CoordinatorException>()));
    expect(tiny.stats()['rejected'], 1);
  });
}

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
