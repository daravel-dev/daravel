import 'dart:async';
import 'dart:isolate';

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
  coordinatorRobustnessTests();
  cacheFrameTests();
  burstTests();
  workerExitTests();
  rateLimitMemoryTests();
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
    expect(stats['messages'], 4, reason: 'handled plus rejected');
    expect(stats['uptime_s'], isA<double>());
    expect(stats['messages_per_second'], isA<double>());
    expect((stats['services'] as Map)['rateLimiter'], {'keys': 1});
    expect(
      () => channel.call('nope', 'x', const {}),
      throwsA(isA<CoordinatorException>()),
    );
  });

  test('merged metrics carry the coordinator message counters', () async {
    final channel = LocalCoordinatorChannel(coordinator);
    await channel.call('rateLimiter', 'attempts', const {
      'key': 'k',
      'decayMs': 60000,
    });
    // What the supervisor's /metrics renders: the workers' snapshots plus
    // the coordinator's own counters.
    final merged = await channel.call(
      MetricsService.serviceName,
      'collect',
      const {},
    ) as Map<String, Object?>;
    final messages = merged['coordinator_messages_total']! as Map;
    expect(messages['type'], 'counter');
    // `attempts` and this `collect` itself.
    expect((messages['series'] as Map)[''], 2.0);
    expect(merged, contains('coordinator_in_flight'));
    expect(
      MetricsRegistry.renderSnapshot(merged),
      contains('coordinator_messages_total 2'),
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

  group('leased rate limiting across workers', () {
    const decay = Duration(minutes: 1);

    test(
      'never exceeds the limit with several workers hammering one key',
      () async {
        final workers = [
          for (var i = 0; i < 4; i++)
            RemoteCoordinatorChannel(coordinator.listen()),
        ];
        for (final channel in workers) {
          addTearDown(channel.close);
        }
        final stores = [for (final c in workers) ProcessRateLimitStore(c)];
        var allowed = 0;
        await Future.wait([
          for (final store in stores)
            () async {
              for (var i = 0; i < 100; i++) {
                if ((await store.attempt('hot', 120, decay)).allowed) {
                  allowed++;
                }
              }
            }(),
        ]);
        expect(allowed, 120);
        final blocked = await stores.first.attempt('hot', 120, decay);
        expect(blocked.allowed, isFalse);
        expect(blocked.retryAfter, isNotNull);
      },
    );

    test('batches grow on hot keys', () async {
      final channel = RemoteCoordinatorChannel(coordinator.listen());
      addTearDown(channel.close);
      // A TTL far above any CI hiccup: leases never expire in this test.
      final store = ProcessRateLimitStore(
        channel,
        leaseTtl: const Duration(minutes: 1),
      );
      // Hot: leases of 1, 2, 4, 8 used up in a row.
      for (var i = 0; i < 15; i++) {
        expect((await store.attempt('k', 1000, decay)).allowed, isTrue);
      }
      final service =
          coordinator.service(RateLimitService.serviceName)!
              as RateLimitService;
      expect(service.store.attemptsSync('k', decay), 15);
      expect(coordinator.stats()['handled'], lessThan(15));
      // One more opens a 16-hit lease.
      await store.attempt('k', 1000, decay);
      expect(service.store.attemptsSync('k', decay), 31);
    });

    test('unused leased hits are released after the lease expires', () async {
      final channel = RemoteCoordinatorChannel(coordinator.listen());
      addTearDown(channel.close);
      final store = ProcessRateLimitStore(
        channel,
        leaseTtl: const Duration(milliseconds: 50),
      );
      final service =
          coordinator.service(RateLimitService.serviceName)!
              as RateLimitService;
      for (var i = 0; i < 4; i++) {
        await store.attempt('k', 1000, decay);
      }
      // Wait well past the TTL: the next attempt releases what was leased
      // but unused and restarts at a batch of 1. However slow the runner
      // (leases may also expire between the first attempts), the
      // coordinator then holds exactly the 5 hits that were served.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await store.attempt('k', 1000, decay);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(service.store.attemptsSync('k', decay), 5);
    });

    test('small limits (login) always ask the coordinator', () async {
      final channel = RemoteCoordinatorChannel(coordinator.listen());
      addTearDown(channel.close);
      final store = ProcessRateLimitStore(channel);
      for (var i = 0; i < 5; i++) {
        expect((await store.attempt('login', 5, decay)).remaining, 4 - i);
      }
      expect((await store.attempt('login', 5, decay)).allowed, isFalse);
    });

    test('a blocked key is answered locally for a short while', () async {
      final channel = RemoteCoordinatorChannel(coordinator.listen());
      addTearDown(channel.close);
      final store = ProcessRateLimitStore(channel);
      final service =
          coordinator.service(RateLimitService.serviceName)!
              as RateLimitService;
      service.store.attemptSync('full', 40, decay, cost: 40);
      expect((await store.attempt('full', 40, decay)).allowed, isFalse);
      final handled = coordinator.stats()['handled']! as int;
      for (var i = 0; i < 10; i++) {
        expect((await store.attempt('full', 40, decay)).allowed, isFalse);
      }
      expect(coordinator.stats()['handled'], handled);
    });
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

/// A service whose answer cannot cross an isolate boundary.
final class _UnsendableService implements CoordinatorService {
  @override
  String get name => 'unsendable';

  @override
  Object? handle(String op, Map<String, Object?> args) =>
      op == 'later' ? Future<Object?>.value(ReceivePort()) : ReceivePort();

  @override
  Map<String, Object?> stats() => const {};
}

void coordinatorRobustnessTests() {
  test('an answer that cannot be sent is an error, not a crash', () async {
    // The listener runs on the supervisor's main isolate, where an uncaught
    // error ends the whole server. A ReceivePort cannot be sent even
    // within one isolate.
    final coordinator = createStandardCoordinator()
      ..register(_UnsendableService());
    addTearDown(coordinator.close);
    final channel = RemoteCoordinatorChannel(coordinator.listen());
    addTearDown(channel.close);
    for (final op in ['now', 'later']) {
      await expectLater(
        channel.call('unsendable', op, const {}),
        throwsA(
          isA<CoordinatorException>().having(
            (e) => e.message,
            'message',
            contains('cannot be sent to a worker'),
          ),
        ),
        reason: op,
      );
    }
    // Still serving.
    expect(
      await channel.call('rateLimiter', 'attempts', const {
        'key': 'k',
        'decayMs': 60000,
      }),
      0,
    );
    expect(coordinator.stats()['in_flight'], 0);
  });

  test('a closed channel refuses calls at once', () async {
    final coordinator = createStandardCoordinator();
    addTearDown(coordinator.close);
    final channel = RemoteCoordinatorChannel(coordinator.listen());
    channel.close();
    final watch = Stopwatch()..start();
    await expectLater(
      channel.call('rateLimiter', 'attempts', const {
        'key': 'k',
        'decayMs': 60000,
      }, timeout: const Duration(seconds: 5)),
      throwsA(
        isA<CoordinatorException>().having(
          (e) => e.message,
          'message',
          'Coordinator channel closed.',
        ),
      ),
    );
    expect(
      watch.elapsed,
      lessThan(const Duration(seconds: 1)),
      reason: 'not the timeout',
    );
    expect(channel.pending, 0);
  });
}

void rateLimitMemoryTests() {
  test('a worker sweeps the state of keys it no longer limits', () async {
    final coordinator = createStandardCoordinator();
    addTearDown(coordinator.close);
    final channel = RemoteCoordinatorChannel(coordinator.listen());
    addTearDown(channel.close);
    final store = ProcessRateLimitStore(
      channel,
      maxKeys: 8,
      leaseTtl: const Duration(milliseconds: 20),
      blockedCacheTtl: const Duration(milliseconds: 20),
    );
    // One key per client, each seen once: a lease (and after a second
    // attempt a batch size) per key, never asked for again.
    for (var i = 0; i < 8; i++) {
      await store.attempt('ip-$i', 100, const Duration(minutes: 1));
      await store.attempt('ip-$i', 100, const Duration(minutes: 1));
    }
    expect(store.trackedKeys, 8);
    await Future<void>.delayed(const Duration(milliseconds: 40));
    // The ninth key reaches maxKeys: the expired leases go back and their
    // batch sizes go with them.
    await store.attempt('ip-8', 100, const Duration(minutes: 1));
    // The expired leases went back with their batch sizes (unused tokens
    // mean the key is not hot); a hot key's size is kept until the batch
    // map itself is full and its older half goes.
    expect(store.trackedKeys, 1);
    expect(
      await store.attempts('ip-0', const Duration(minutes: 1)),
      2,
      reason: 'the hits were used; only unused leased tokens went back',
    );
  });
}

void workerExitTests() {
  test('a worker that exits takes its members and ports with it', () async {
    final coordinator = createStandardCoordinator();
    addTearDown(coordinator.close);
    final channel = LocalCoordinatorChannel(coordinator);
    Future<Object?> join(String worker, String socket, String user) =>
        channel.call('channels', 'join', {
          'channel': 'presence-room',
          'socket': socket,
          'user_id': user,
          'user_info': {'name': user},
          'worker': worker,
        });
    await join('daravel-worker-0', 's1', 'ana');
    await join('daravel-worker-1', 's2', 'bo');
    await join('daravel-worker-1', 's3', 'cy');
    final inbox0 = ReceivePort();
    final inbox1 = ReceivePort();
    addTearDown(inbox0.close);
    addTearDown(inbox1.close);
    for (final (worker, port) in [
      ('daravel-worker-0', inbox0.sendPort),
      ('daravel-worker-1', inbox1.sendPort),
    ]) {
      await channel.call('broadcast', 'subscribe', {
        'channel': 'news',
        'port': port,
        'worker': worker,
      });
    }
    expect(
      await channel.call('channels', 'users', {'channel': 'presence-room'}),
      ['ana', 'bo', 'cy'],
    );
    expect(
      await channel.call('broadcast', 'publish', {
        'channel': 'news',
        'message': 'x',
      }),
      2,
    );

    // Worker 1 crashes: its two sockets never sent `leave`, its port never
    // `unsubscribe`.
    coordinator.forgetWorker('daravel-worker-1');
    expect(
      await channel.call('channels', 'users', {'channel': 'presence-room'}),
      ['ana'],
      reason: 'no ghost members',
    );
    expect(
      await channel.call('channels', 'channel', {'channel': 'presence-room'}),
      {'occupied': true, 'subscription_count': 1, 'user_count': 1},
    );
    expect(
      await channel.call('broadcast', 'publish', {
        'channel': 'news',
        'message': 'y',
      }),
      1,
      reason: 'the dead port is gone',
    );
    // The channel empties once the last worker goes.
    coordinator.forgetWorker('daravel-worker-0');
    expect(
      await channel.call('channels', 'channel', {'channel': 'presence-room'}),
      {'occupied': false, 'subscription_count': 0, 'user_count': 0},
    );
    expect((coordinator.stats()['services'] as Map)['broadcast'], {
      'channels': 0,
      'published': 2,
      'delivered': 3,
    });
    // Unknown workers are a no-op.
    coordinator.forgetWorker('daravel-worker-9');
  });
}

void burstTests() {
  test(
    'locks and presence stay consistent under a burst from workers',
    () async {
      final coordinator = createStandardCoordinator();
      addTearDown(coordinator.close);
      final workers = [
        for (var i = 0; i < 4; i++)
          RemoteCoordinatorChannel(coordinator.listen()),
      ];
      for (final channel in workers) {
        addTearDown(channel.close);
      }
      final stores = [for (final c in workers) ProcessStore(c)];

      // 200 attempts at one lock at the same time: exactly one holder, every
      // call answered (no hang, no timeout), and the lock passes on cleanly.
      for (var round = 0; round < 3; round++) {
        final results = await Future.wait([
          for (var w = 0; w < stores.length; w++)
            for (var i = 0; i < 50; i++)
              stores[w].acquireLock(
                'job',
                'w$w-$i',
                const Duration(seconds: 5),
              ),
        ]).timeout(const Duration(seconds: 10));
        expect(
          results.where((won) => won),
          hasLength(1),
          reason: 'round $round',
        );
        final owner = (await stores.first.lockOwner('job'))!;
        final holder = stores[int.parse(owner.substring(1, 2))];
        expect(await holder.releaseLock('job', owner), isTrue);
        expect(await stores.last.lockOwner('job'), isNull);
      }

      // 400 joins and leaves interleaved from four workers: the member list
      // ends up with exactly the sockets that stayed.
      final presence = <Future<Object?>>[];
      for (var w = 0; w < workers.length; w++) {
        for (var i = 0; i < 100; i++) {
          presence.add(
            workers[w].call('channels', 'join', {
              'channel': 'presence-burst',
              'socket': 's$w-$i',
              'user_id': 'u$w-$i',
              'user_info': null,
              'worker': 'daravel-worker-$w',
            }),
          );
          if (i.isOdd) {
            presence.add(
              workers[w].call('channels', 'leave', {
                'channel': 'presence-burst',
                'socket': 's$w-$i',
              }),
            );
          }
        }
      }
      await Future.wait(presence).timeout(const Duration(seconds: 10));
      final info = await workers.first.call('channels', 'channel', {
        'channel': 'presence-burst',
      }) as Map<Object?, Object?>;
      expect(info['subscription_count'], 200, reason: 'the even sockets');
      expect(info['user_count'], 200);
      expect(coordinator.stats()['in_flight'], 0);
      for (final channel in workers) {
        expect(channel.pending, 0, reason: 'every call was answered');
      }
    },
  );
}

void cacheFrameTests() {
  test('cache channel frames are bounded and expired ones swept', () async {
    Clock.fake(DateTime.utc(2026, 10, 28, 8));
    addTearDown(Clock.restore);
    final service = ChannelMembershipService();
    Object? call(String op, Map<String, Object?> args) =>
        service.handle(op, args);
    for (var i = 0; i < ChannelMembershipService.maxCachedFrames; i++) {
      call('cache_set', {'channel': 'cache-doc-$i', 'frame': 'f$i'});
    }
    expect(service.cachedFrames, ChannelMembershipService.maxCachedFrames);
    // One more with every frame still fresh: the least recently written
    // goes, the newest stays, the rest are served.
    call('cache_set', {'channel': 'cache-doc-new', 'frame': 'new'});
    expect(service.cachedFrames, ChannelMembershipService.maxCachedFrames);
    expect(call('cache_get', {'channel': 'cache-doc-0'}), isNull);
    expect(call('cache_get', {'channel': 'cache-doc-1'}), 'f1');
    expect(call('cache_get', {'channel': 'cache-doc-new'}), 'new');
    // Rewriting a channel moves it to the end instead of growing the map.
    call('cache_set', {'channel': 'cache-doc-1', 'frame': 'f1b'});
    expect(service.cachedFrames, ChannelMembershipService.maxCachedFrames);
    // Past the TTL the expired frames go first, all at once.
    Clock.travel(
      ChannelMembershipService.cacheTtl + const Duration(seconds: 1),
    );
    call('cache_set', {'channel': 'cache-doc-fresh', 'frame': 'fresh'});
    expect(service.cachedFrames, 1);
    expect(call('cache_get', {'channel': 'cache-doc-fresh'}), 'fresh');
  });
}
