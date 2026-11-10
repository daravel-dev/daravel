import 'dart:async';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A package's service that says nothing of its priority: normal.
final class _Plain implements CoordinatorService {
  @override
  String get name => 'plain';

  @override
  Object? handle(String op, Map<String, Object?> args) => args['v'];

  @override
  Map<String, Object?> stats() => const {};
}

/// Telemetry: a service that opts into bulk. Each call takes [cost] of
/// this isolate's time, so calls put off are still queued for a while.
final class _Bulk with PrioritizedService implements CoordinatorService {
  _Bulk([this.cost = Duration.zero]);

  final Duration cost;

  @override
  CoordinatorPriority get priority => CoordinatorPriority.bulk;

  @override
  String get name => 'bulk';

  @override
  Object? handle(String op, Map<String, Object?> args) {
    _block(cost);
    return args['v'];
  }

  @override
  Map<String, Object?> stats() => const {};
}

/// A message its caller gives up on at its deadline.
final class _Expiring implements ExpiringCoordinatorMessage {
  const _Expiring();

  @override
  bool get expiresWithCall => true;
}

/// A bulk service taking [_Expiring] messages.
final class _ExpiringBulk
    with PrioritizedService
    implements TypedCoordinatorService<_Expiring> {
  int handled = 0;

  @override
  CoordinatorPriority get priority => CoordinatorPriority.bulk;

  @override
  String get name => 'expiring';

  @override
  Object? handle(String op, Map<String, Object?> args) => null;

  @override
  Object? handleTyped(_Expiring message) => ++handled;

  @override
  Map<String, Object?> stats() => const {};
}

/// Blocks this isolate's event loop for [d]: the coordinator's lag probe,
/// due meanwhile, fires that late.
void _block(Duration d) {
  final watch = Stopwatch()..start();
  while (watch.elapsed < d) {}
}

Future<void> _until(bool Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// Sends raw [CoordinatorRequest]s, answered on one port, so a test can
/// set a call's deadline itself.
final class _RawCaller {
  _RawCaller(this.target) {
    _port.handler = (Object? message) {
      if (message is CoordinatorReply) {
        _pending.remove(message.id)?.complete(message);
      }
    };
  }

  final SendPort target;
  final RawReceivePort _port = RawReceivePort();
  final Map<int, Completer<CoordinatorReply>> _pending = {};
  int _next = 0;

  Future<CoordinatorReply> call(
    String service,
    Object args, {
    int deadline = 0,
  }) {
    final id = _next++;
    final completer = _pending[id] = Completer<CoordinatorReply>();
    target.send(
      CoordinatorRequest(
        id: id,
        service: service,
        op: 'x',
        args: args,
        replyTo: _port.sendPort,
        deadline: deadline,
      ),
    );
    return completer.future;
  }

  int get unanswered => _pending.length;

  void close() => _port.close();
}

void main() {
  final coordinators = <Coordinator>[];
  final channels = <RemoteCoordinatorChannel>[];
  final callers = <_RawCaller>[];

  tearDown(() {
    for (final c in channels) {
      c.close();
    }
    for (final c in callers) {
      c.close();
    }
    for (final c in coordinators) {
      c.close();
    }
    channels.clear();
    callers.clear();
    coordinators.clear();
  });

  Coordinator coordinator({
    Duration lagWarn = const Duration(milliseconds: 5),
    Duration lagShed = const Duration(milliseconds: 50),
    int maxQueue = 10000,
    List<CoordinatorService> extra = const [],
  }) {
    final standard = createStandardCoordinator();
    final c = Coordinator(
      lagWarn: lagWarn,
      lagShed: lagShed,
      maxQueue: maxQueue,
    );
    for (final name in standard.serviceNames) {
      c.register(standard.service(name)!);
    }
    for (final service in extra) {
      c.register(service);
    }
    coordinators.add(c);
    return c;
  }

  RemoteCoordinatorChannel channelTo(Coordinator c) {
    final channel = RemoteCoordinatorChannel(c.listen());
    channels.add(channel);
    return channel;
  }

  _RawCaller rawTo(Coordinator c) {
    final caller = _RawCaller(c.listen());
    callers.add(caller);
    return caller;
  }

  /// Late lag probes until [c] is lagging.
  Future<void> makeLagging(Coordinator c) async {
    while (c.state != CoordinatorState.lagging) {
      _block(const Duration(milliseconds: 120));
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  test('the standard services say their priority; an unmarked one is '
      'normal', () {
    final c = coordinator(extra: [_Plain(), _Bulk()]);
    expect(
      c.priorityOf(RateLimitService.serviceName),
      CoordinatorPriority.critical,
    );
    expect(
      c.priorityOf(ProcessCacheService.jwtDenylistServiceName),
      CoordinatorPriority.critical,
    );
    expect(
      c.priorityOf(ProcessCacheService.serviceName),
      CoordinatorPriority.normal,
    );
    expect(c.priorityOf('channels'), CoordinatorPriority.normal);
    expect(c.priorityOf('broadcast'), CoordinatorPriority.bulk);
    expect(c.priorityOf(MetricsService.serviceName), CoordinatorPriority.bulk);
    expect(c.priorityOf('plain'), CoordinatorPriority.normal);
    expect(c.priorityOf('bulk'), CoordinatorPriority.bulk);
    // The process cache's locks are critical, its reads normal.
    final cache =
        c.service(ProcessCacheService.serviceName)! as PrioritizedService;
    expect(
      cache.priorityFor('acquireLock', const {}),
      CoordinatorPriority.critical,
    );
    expect(
      cache.priorityFor('releaseLock', const {}),
      CoordinatorPriority.critical,
    );
    expect(cache.priorityFor('get', const {}), CoordinatorPriority.normal);
  });

  test('saturated: workers hear it, bulk calls fail at once, unmarked and '
      'critical ones still answer, healthy again once the loop is', () async {
    final c = coordinator(
      lagWarn: const Duration(milliseconds: 2),
      lagShed: const Duration(milliseconds: 20),
      extra: [_Plain(), _Bulk()],
    );
    final channel = channelTo(c);
    final states = <CoordinatorState>[];
    final shortCircuited = <String>[];
    channel
      ..onStateChange = states.add
      ..onShortCircuit = shortCircuited.add;
    // A call first: the coordinator learns this worker's port.
    expect(await channel.call('bulk', 'x', {'v': 1}), 1);

    _block(const Duration(milliseconds: 250));
    await _until(
      () => channel.coordinatorState == CoordinatorState.saturated,
      'the saturated announcement',
    );
    expect(c.state, CoordinatorState.saturated);
    expect(states, contains(CoordinatorState.saturated));

    // Bulk: failed in the worker, without a round trip.
    final watch = Stopwatch()..start();
    await expectLater(
      channel.call('bulk', 'x', {'v': 2}),
      throwsA(isA<CoordinatorOverloaded>()),
    );
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 20)));
    expect(shortCircuited, contains('bulk'));

    // Unmarked: put off, still answered.
    expect(await channel.call('plain', 'x', {'v': 3}), 3);

    // Critical: a lock is still answered.
    final store = ProcessStore(channel);
    expect(
      await store.acquireLock('k1-lock', 'me', const Duration(seconds: 5)),
      isTrue,
    );

    // Rate limit: the limit's failure policy now, not after the timeout.
    final limits = ProcessRateLimitStore(
      channel,
      timeout: const Duration(seconds: 2),
    );
    final limited = Stopwatch()..start();
    final result = await limits.attempt('k1', 5, const Duration(minutes: 1));
    expect(limited.elapsed, lessThan(const Duration(milliseconds: 100)));
    expect(result.degraded, isTrue);
    expect(result.allowed, isTrue);
    expect(shortCircuited, contains(RateLimitService.serviceName));

    // Quiet again: healthy, and bulk calls go through.
    await _until(
      () => channel.coordinatorState == CoordinatorState.healthy,
      'the healthy announcement',
    );
    expect(await channel.call('bulk', 'x', {'v': 4}), 4);
  });

  test('a worker first heard from while saturated is told before its '
      'reply', () async {
    final c = coordinator(
      lagWarn: const Duration(milliseconds: 2),
      lagShed: const Duration(milliseconds: 20),
      extra: [_Bulk()],
    );
    // Some worker, so the coordinator's state has someone to go to.
    expect(await channelTo(c).call('bulk', 'x', {'v': 0}), 0);
    _block(const Duration(milliseconds: 250));
    await _until(() => c.state == CoordinatorState.saturated, 'saturated');

    final spawned = channelTo(c);
    expect(spawned.coordinatorState, CoordinatorState.healthy);
    await expectLater(
      spawned.call('bulk', 'x', {'v': 1}),
      throwsA(isA<CoordinatorOverloaded>()),
    );
    // The health message came before the refusal, not a second later.
    expect(spawned.coordinatorState, CoordinatorState.saturated);
    expect(
      (c.stats()['shed']! as Map<String, Object?>)['bulk'],
      greaterThanOrEqualTo(1),
    );
  });

  test('lagging: bulk calls are put off and answered', () async {
    final c = coordinator(
      lagWarn: const Duration(milliseconds: 2),
      lagShed: const Duration(seconds: 30),
      extra: [_Bulk()],
    );
    final channel = channelTo(c);
    expect(await channel.call('bulk', 'x', {'v': 0}), 0);
    await makeLagging(c);
    final answers = await Future.wait([
      for (var i = 0; i < 10; i++) channel.call('bulk', 'x', {'v': i}),
    ]);
    expect(answers, [for (var i = 0; i < 10; i++) i]);
    expect(c.stats()['deferred_peak'], greaterThanOrEqualTo(1));
    final served = c.stats()['served_by_priority']! as Map<String, Object?>;
    expect(served['bulk'], greaterThanOrEqualTo(10));
  });

  test('critical calls are neither put off nor refused, even with the '
      'queue of calls put off full', () async {
    final c = coordinator(
      lagWarn: const Duration(milliseconds: 2),
      lagShed: const Duration(seconds: 30),
      maxQueue: 4,
      extra: [_Bulk(const Duration(milliseconds: 20))],
    );
    final raw = rawTo(c);
    final channel = channelTo(c);
    expect((await raw.call('bulk', {'v': 0})).result, 0);
    await makeLagging(c);

    final order = <String>[];
    final bulk = [
      for (var i = 0; i < 10; i++)
        raw.call('bulk', {'v': i}).then((reply) {
          order.add(reply.error == null ? 'bulk' : 'refused');
          return reply;
        }),
    ];
    final lock = ProcessStore(channel)
        .acquireLock('k1-full', 'me', const Duration(seconds: 5))
        .then((taken) {
          order.add('lock');
          return taken;
        });
    expect(await lock, isTrue);
    final replies = await Future.wait(bulk);

    // Ten bulk calls against a queue of four: the rest refused, and the
    // coordinator saturated by the full queue.
    expect(replies.where((r) => r.error != null), isNotEmpty);
    expect(c.stats()['deferred_peak'], lessThanOrEqualTo(4));
    // The lock, sent after them, was answered before the calls put off.
    expect(order.indexOf('lock'), lessThan(order.lastIndexOf('bulk')));
  });

  test('a call that expires while put off is dropped, unanswered', () async {
    final expiring = _ExpiringBulk();
    final c = coordinator(
      lagWarn: const Duration(milliseconds: 2),
      lagShed: const Duration(seconds: 30),
      extra: [_Bulk(const Duration(milliseconds: 15)), expiring],
    );
    final raw = rawTo(c);
    expect((await raw.call('bulk', {'v': 0})).result, 0);
    await makeLagging(c);
    final expiredBefore = c.stats()['expired']! as int;

    // Six slow calls put off ahead of it: 90 ms before it is reached, past
    // its 30 ms deadline.
    final ahead = [
      for (var i = 0; i < 6; i++) raw.call('bulk', {'v': i}),
    ];
    unawaited(
      raw.call(
        'expiring',
        const _Expiring(),
        deadline: DateTime.now()
            .add(const Duration(milliseconds: 30))
            .microsecondsSinceEpoch,
      ),
    );
    await Future.wait(ahead);
    await _until(
      () => (c.stats()['expired']! as int) > expiredBefore,
      'the expired count',
    );
    expect(expiring.handled, 0);
    expect(raw.unanswered, 1);
  });

  test('state improves only after several quiet measurements', () async {
    final c = coordinator(
      lagWarn: const Duration(milliseconds: 2),
      lagShed: const Duration(milliseconds: 20),
      extra: [_Bulk()],
    );
    final channel = channelTo(c);
    expect(await channel.call('bulk', 'x', {'v': 0}), 0);
    final changes = <CoordinatorState>[];
    channel.onStateChange = changes.add;

    _block(const Duration(milliseconds: 250));
    await _until(() => c.state == CoordinatorState.saturated, 'saturated');
    final quiet = Stopwatch()..start();
    await _until(() => c.state == CoordinatorState.healthy, 'healthy');
    // Recovery waits for Coordinator.recoverySamples quiet probes.
    expect(
      quiet.elapsed,
      greaterThanOrEqualTo(
        Coordinator.lagProbeInterval * (Coordinator.recoverySamples - 1),
      ),
    );
    await _until(
      () => channel.coordinatorState == CoordinatorState.healthy,
      'the healthy announcement',
    );
    // Saturated once, then healthy: no flapping back.
    expect(changes.where((s) => s == CoordinatorState.saturated), hasLength(1));
    expect(changes.last, CoordinatorState.healthy);
  });

  test('the local channel has no queue and no health: answered while the '
      'coordinator is saturated', () async {
    final c = coordinator(
      lagWarn: const Duration(milliseconds: 2),
      lagShed: const Duration(milliseconds: 20),
      extra: [_Bulk()],
    );
    expect(await channelTo(c).call('bulk', 'x', {'v': 0}), 0);
    _block(const Duration(milliseconds: 250));
    await _until(() => c.state == CoordinatorState.saturated, 'saturated');

    final local = LocalCoordinatorChannel(c);
    expect(await local.call('bulk', 'x', {'v': 1}), 1);
    expect(c.deferred, 0);
  });

  test('the health message is deeply immutable and the stats are on '
      '/metrics', () {
    const health = CoordinatorHealth(2, 1000, 3, 'broadcast,bulk');
    expect(health.state, CoordinatorState.saturated.index);
    final snapshot = MetricsService.coordinatorSnapshot({
      'state': 'lagging',
      'deferred': 4,
      'deferred_peak': 9,
      'shed': {'broadcast': 7},
      'served_by_priority': {'critical': 1, 'normal': 2, 'bulk': 3},
    });
    expect((snapshot['coordinator_health']! as Map)['series'], {
      'state="healthy"': 0.0,
      'state="lagging"': 1.0,
      'state="saturated"': 0.0,
    });
    expect((snapshot['coordinator_shed_total']! as Map)['series'], {
      'service="broadcast"': 7.0,
    });
    expect((snapshot['coordinator_served_total']! as Map)['series'], {
      'priority="critical"': 1.0,
      'priority="normal"': 2.0,
      'priority="bulk"': 3.0,
    });
  });
}
