import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A channel that is only a [CoordinatorChannel] (an application's own, a
/// test double): the stores must fall back to maps.
final class _MapOnlyChannel implements CoordinatorChannel {
  _MapOnlyChannel(this._inner);

  final CoordinatorChannel _inner;
  final List<String> ops = [];

  @override
  StateScope get scope => _inner.scope;

  @override
  bool get isRemote => _inner.isRemote;

  @override
  Future<Object?> call(
    String service,
    String op,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 1),
  }) {
    ops.add(op);
    return _inner.call(service, op, args, timeout: timeout);
  }
}

/// Keeps the last message it was sent.
final class _RecordingService
    implements TypedCoordinatorService<RateLimitMessage> {
  RateLimitMessage? last;

  @override
  String get name => 'recording';

  @override
  Object? handle(String op, Map<String, Object?> args) => 'map:$op';

  @override
  Object? handleTyped(RateLimitMessage message) {
    last = message;
    return 'typed:${message.op}';
  }

  @override
  Map<String, Object?> stats() => const {};
}

Object? _plain(Object? result) => switch (result) {
  final RateLimitResult r => [
    r.allowed,
    r.limit,
    r.remaining,
    r.resetAt.millisecondsSinceEpoch,
    r.retryAfter?.inMilliseconds,
    r.degraded,
  ],
  final RateLimitGrant g => [g.granted, g.hits, g.resetAtMs],
  _ => result,
};

/// Every rate limit and lock operation, typed, through [channel].
Future<List<Object?>> _typedScript(TypedCoordinatorChannel channel) async {
  const limiter = RateLimitService.serviceName;
  const cache = ProcessCacheService.serviceName;
  final results = <Object?>[];
  Future<void> run(String service, Object message) async =>
      results.add(_plain(await channel.callTyped(service, message)));

  for (var i = 0; i < 3; i++) {
    await run(
      limiter,
      const RateLimitMessage('attempt', 'login', max: 2, decayMs: 60000),
    );
  }
  await run(
    limiter,
    const RateLimitMessage('acquire', 'api', max: 10, decayMs: 60000, want: 4),
  );
  final grant = await channel.callTyped(
    limiter,
    const RateLimitMessage('acquire', 'api', max: 10, decayMs: 60000, want: 8),
  ) as RateLimitGrant;
  results.add(_plain(grant));
  await run(
    limiter,
    RateLimitMessage('release', 'api', count: 3, resetAt: grant.resetAtMs),
  );
  await run(limiter, const RateLimitMessage('attempts', 'api', decayMs: 60000));
  await run(
    limiter,
    const RateLimitMessage('availableIn', 'login', max: 2, decayMs: 60000),
  );
  // What clear answers is not part of the contract (the store ignores it).
  await channel.callTyped(limiter, const RateLimitMessage('clear', 'login'));
  results.add('cleared');
  await run(
    limiter,
    const RateLimitMessage('attempts', 'login', decayMs: 60000),
  );

  await run(
    cache,
    const LockMessage('acquireLock', 'job', owner: 'a', ttlMs: 10000),
  );
  await run(
    cache,
    const LockMessage('acquireLock', 'job', owner: 'b', ttlMs: 10000),
  );
  await run(cache, const LockMessage('lockOwner', 'job'));
  await run(cache, const LockMessage('releaseLock', 'job', owner: 'b'));
  await run(cache, const LockMessage('releaseLock', 'job', owner: 'a'));
  await run(
    cache,
    const LockMessage('acquireLock', 'job', owner: 'b', ttlMs: 10000),
  );
  await run(cache, const LockMessage('forceReleaseLock', 'job'));
  await run(cache, const LockMessage('lockOwner', 'job'));
  return results;
}

/// The same calls through the stores' public API.
Future<List<Object?>> _storeScript(CoordinatorChannel channel) async {
  final limiter = ProcessRateLimitStore(channel);
  final locks = ProcessStore(channel);
  const minute = Duration(minutes: 1);
  return [
    for (var i = 0; i < 3; i++)
      _plain(await limiter.attempt('login', 2, minute)),
    await limiter.attempts('login', minute),
    (await limiter.availableIn('login', 2, minute)).inMilliseconds,
    await limiter.clear('login').then((_) => 'cleared'),
    await limiter.attempts('login', minute),
    await locks.acquireLock('job', 'a', const Duration(seconds: 10)),
    await locks.acquireLock('job', 'b', const Duration(seconds: 10)),
    await locks.lockOwner('job'),
    await locks.releaseLock('job', 'b'),
    await locks.releaseLock('job', 'a'),
    await locks.acquireLock('job', 'b', const Duration(seconds: 10)),
    await locks.forceReleaseLock('job').then((_) => 'forced'),
    await locks.lockOwner('job'),
    await limiter.flush().then((_) => 'flushed'),
  ];
}

void main() {
  setUp(() => Clock.fake(DateTime.utc(2026, 11, 5, 12)));
  tearDown(Clock.restore);

  test('local and remote channels answer typed messages alike', () async {
    final local = createStandardCoordinator();
    addTearDown(local.close);
    final remote = createStandardCoordinator();
    addTearDown(remote.close);
    final channel = RemoteCoordinatorChannel(remote.listen());
    addTearDown(channel.close);

    final here = await _typedScript(LocalCoordinatorChannel(local));
    final there = await _typedScript(channel);
    expect(there, here);
    expect(here, [
      [true, 2, 1, 1793880060000, null, false],
      [true, 2, 0, 1793880060000, null, false],
      [false, 2, 0, 1793880060000, 60000, false],
      [4, 4, 1793880060000],
      [6, 10, 1793880060000],
      7,
      7,
      60000,
      'cleared',
      0,
      true,
      false,
      'a',
      false,
      true,
      true,
      null,
      null,
    ]);
  });

  test('the stores give the same answers through a map-only channel, '
      'which they call with maps', () async {
    final typed = createStandardCoordinator();
    addTearDown(typed.close);
    final mapped = createStandardCoordinator();
    addTearDown(mapped.close);
    final mapOnly = _MapOnlyChannel(LocalCoordinatorChannel(mapped));

    final viaTyped = await _storeScript(LocalCoordinatorChannel(typed));
    final viaMaps = await _storeScript(mapOnly);
    expect(viaMaps, viaTyped);
    expect(mapOnly.ops, [
      'attempt',
      'attempt',
      'attempt',
      'attempts',
      'availableIn',
      'clear',
      'attempts',
      'acquireLock',
      'acquireLock',
      'lockOwner',
      'releaseLock',
      'releaseLock',
      'acquireLock',
      'forceReleaseLock',
      'lockOwner',
      'flush',
    ]);
  });

  test('the remote stores use the typed path end to end', () async {
    final coordinator = createStandardCoordinator();
    addTearDown(coordinator.close);
    final channel = RemoteCoordinatorChannel(coordinator.listen());
    addTearDown(channel.close);
    final local = createStandardCoordinator();
    addTearDown(local.close);

    expect(
      await _storeScript(channel),
      await _storeScript(LocalCoordinatorChannel(local)),
    );
  });

  test('a deeply immutable message reaches the coordinator uncopied', () async {
    final service = _RecordingService();
    final coordinator = Coordinator()..register(service);
    addTearDown(coordinator.close);
    final channel = RemoteCoordinatorChannel(coordinator.listen());
    addTearDown(channel.close);

    final message = RateLimitMessage('attempt', 'k${DateTime.now()}', max: 1);
    expect(await channel.callTyped('recording', message), 'typed:attempt');
    expect(identical(service.last, message), isTrue);
    // A map still goes to handle().
    expect(
      await channel.call('recording', 'attempts', const {}),
      'map:attempts',
    );
  });

  test('a map-based service keeps working on both channels', () async {
    final coordinator = createStandardCoordinator();
    addTearDown(coordinator.close);
    final remote = RemoteCoordinatorChannel(coordinator.listen());
    addTearDown(remote.close);
    final inbox = ReceivePort();
    addTearDown(inbox.close);

    for (final channel in <CoordinatorChannel>[
      LocalCoordinatorChannel(coordinator),
      remote,
    ]) {
      await channel.call('broadcast', 'subscribe', {
        'channel': 'orders',
        'port': inbox.sendPort,
      });
      expect(
        await channel.call('broadcast', 'publish', {
          'channel': 'orders',
          'message': 'shipped',
        }),
        1,
      );
      await channel.call('broadcast', 'unsubscribe', {
        'channel': 'orders',
        'port': inbox.sendPort,
      });
    }
    expect(await inbox.take(2).toList(), [
      ['orders', 'shipped'],
      ['orders', 'shipped'],
    ]);
  });

  test('a typed message to a service that takes none is an error', () async {
    final coordinator = createStandardCoordinator();
    addTearDown(coordinator.close);
    final remote = RemoteCoordinatorChannel(coordinator.listen());
    addTearDown(remote.close);
    const message = RateLimitMessage('publish', 'x');

    await expectLater(
      LocalCoordinatorChannel(coordinator).callTyped('broadcast', message),
      throwsA(
        isA<CoordinatorException>().having(
          (e) => e.message,
          'message',
          contains('takes no typed messages'),
        ),
      ),
    );
    await expectLater(
      remote.callTyped('broadcast', message),
      throwsA(isA<CoordinatorException>()),
    );
  });

  test('LockMessage.toArgs and RateLimitMessage.toArgs match handle()', () {
    expect(
      const LockMessage('acquireLock', 'job', owner: 'a', ttlMs: 5).toArgs(),
      {'key': 'job', 'owner': 'a', 'ttl': 5},
    );
    expect(const LockMessage('lockOwner', 'job').toArgs(), {'key': 'job'});
    expect(
      const RateLimitMessage(
        'acquire',
        'api',
        max: 3,
        decayMs: 10,
        want: 2,
      ).toArgs(),
      {
        'key': 'api',
        'max': 3,
        'decay': 10,
        'want': 2,
        'count': 0,
        'resetAt': 0,
      },
    );
  });
}
