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
/// this isolate's time, so calls put off stay queued for a while.
final class _Bulk with PrioritizedService implements CoordinatorService {
  _Bulk([this.cost = Duration.zero]);

  final Duration cost;

  @override
  CoordinatorPriority get priority => CoordinatorPriority.bulk;

  @override
  String get name => 'bulk';

  @override
  Object? handle(String op, Map<String, Object?> args) {
    final watch = Stopwatch()..start();
    while (watch.elapsed < cost) {}
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

/// Lags fed to [Coordinator.observeLag] against the thresholds the tests
/// use (warn 5 ms, shed 50 ms).
const _quiet = Duration.zero;
const _slow = Duration(milliseconds: 10);
const _stuck = Duration(milliseconds: 80);

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

  /// A coordinator whose own probe does not run during a test: the test
  /// gives it the lag ([Coordinator.observeLag]).
  Coordinator coordinator({
    int maxQueue = 10000,
    List<CoordinatorService> extra = const [],
  }) {
    final standard = createStandardCoordinator();
    final c = Coordinator(
      maxQueue: maxQueue,
      probeEvery: const Duration(hours: 1),
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

  void observe(Coordinator c, Duration lag, [int times = 1]) {
    for (var i = 0; i < times; i++) {
      c.observeLag(lag);
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

  test('saturated: workers hear it, bulk calls fail in the worker, unmarked '
      'and critical ones are answered, and it recovers', () async {
    final c = coordinator(extra: [_Plain(), _Bulk()]);
    final channel = channelTo(c);
    final states = <CoordinatorState>[];
    final shortCircuited = <String>[];
    channel
      ..onStateChange = states.add
      ..onShortCircuit = shortCircuited.add;
    // A call first: the coordinator learns this worker's port.
    expect(await channel.call('bulk', 'x', {'v': 1}), 1);

    observe(c, _stuck);
    expect(c.state, CoordinatorState.saturated);
    await pumpEventQueue();
    expect(channel.coordinatorState, CoordinatorState.saturated);
    expect(states, [CoordinatorState.saturated]);

    // Bulk: failed in the worker, never sent (the coordinator sheds none).
    await expectLater(
      channel.call('bulk', 'x', {'v': 2}),
      throwsA(isA<CoordinatorOverloaded>()),
    );
    expect(shortCircuited, ['bulk']);
    expect(c.stats()['shed'], isEmpty);

    // Unmarked: put off, still answered.
    expect(await channel.call('plain', 'x', {'v': 3}), 3);

    // Critical: a lock is answered.
    expect(
      await ProcessStore(channel)
          .acquireLock('k1-lock', 'me', const Duration(seconds: 5)),
      isTrue,
    );

    // Rate limit: the limit's failure policy at once, not after its
    // timeout (an hour here: waiting for it would time the test out).
    final limits = ProcessRateLimitStore(
      channel,
      timeout: const Duration(hours: 1),
    );
    final result = await limits.attempt('k1', 5, const Duration(minutes: 1));
    expect(result.degraded, isTrue);
    expect(result.allowed, isTrue);
    expect(shortCircuited, contains(RateLimitService.serviceName));

    // Quiet again: healthy, and bulk calls go through.
    observe(c, _quiet, Coordinator.recoverySamples);
    await pumpEventQueue();
    expect(channel.coordinatorState, CoordinatorState.healthy);
    expect(await channel.call('bulk', 'x', {'v': 4}), 4);
  });

  test('a worker first heard from while saturated is told before its '
      'reply', () async {
    final c = coordinator(extra: [_Bulk()]);
    observe(c, _stuck);
    expect(c.state, CoordinatorState.saturated);

    final spawned = channelTo(c);
    expect(spawned.coordinatorState, CoordinatorState.healthy);
    await expectLater(
      spawned.call('bulk', 'x', {'v': 1}),
      throwsA(isA<CoordinatorOverloaded>()),
    );
    // The health message came first, not at the next announcement.
    expect(spawned.coordinatorState, CoordinatorState.saturated);
    expect((c.stats()['shed']! as Map<String, Object?>)['bulk'], 1);
  });

  test('lagging after three slow measurements: bulk calls are put off and '
      'answered', () async {
    final c = coordinator(extra: [_Bulk()]);
    final channel = channelTo(c);
    observe(c, _slow, 2);
    expect(c.state, CoordinatorState.healthy);
    observe(c, _slow);
    expect(c.state, CoordinatorState.lagging);

    final answers = await Future.wait([
      for (var i = 0; i < 10; i++) channel.call('bulk', 'x', {'v': i}),
    ]);
    expect(answers, [for (var i = 0; i < 10; i++) i]);
    expect(c.stats()['deferred_peak'], 10);
    final served = c.stats()['served_by_priority']! as Map<String, Object?>;
    expect(served['bulk'], 10);
  });

  test('critical calls are neither put off nor refused, even with the '
      'queue of calls put off full', () async {
    final c = coordinator(maxQueue: 4, extra: [_Bulk()]);
    final raw = rawTo(c);
    final channel = channelTo(c);
    observe(c, _slow, 3);
    expect(c.state, CoordinatorState.lagging);

    final bulk = [
      for (var i = 0; i < 10; i++) raw.call('bulk', {'v': i}),
    ];
    final lock = ProcessStore(channel)
        .acquireLock('k1-full', 'me', const Duration(seconds: 5));
    expect(await lock, isTrue);
    final replies = await Future.wait(bulk);

    // Ten bulk calls against a queue of four: the full queue saturates
    // the coordinator and the rest are refused; the lock is not.
    expect(replies.where((r) => r.error != null).length, greaterThan(5));
    expect(c.stats()['deferred_peak'], 4);
    expect(c.state, CoordinatorState.saturated);
    final served = c.stats()['served_by_priority']! as Map<String, Object?>;
    expect(served['critical'], 1);
  });

  test('a call that expires while put off is dropped, unanswered', () async {
    final expiring = _ExpiringBulk();
    final c = coordinator(
      extra: [_Bulk(const Duration(milliseconds: 15)), expiring],
    );
    final raw = rawTo(c);
    observe(c, _slow, 3);
    expect(c.state, CoordinatorState.lagging);

    // Six calls of 15 ms put off ahead of it: about 90 ms before it is
    // reached, past its 30 ms deadline (the deadline is wall clock, as
    // workers and the coordinator share no other).
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
    await pumpEventQueue();
    expect(c.stats()['expired'], 1);
    expect(expiring.handled, 0);
    expect(raw.unanswered, 1);
  });

  test('worse at once, better only after several quiet measurements', () {
    final c = coordinator();
    observe(c, _stuck);
    expect(c.state, CoordinatorState.saturated);

    // Quiet, then stuck again: still saturated, no flapping.
    observe(c, _quiet, Coordinator.recoverySamples - 1);
    expect(c.state, CoordinatorState.saturated);
    observe(c, _stuck);
    observe(c, _quiet, Coordinator.recoverySamples - 1);
    expect(c.state, CoordinatorState.saturated);
    observe(c, _quiet);
    expect(c.state, CoordinatorState.healthy);

    // Saturated, then only slow: lagging, then healthy once quiet.
    observe(c, _stuck);
    observe(c, _slow, Coordinator.recoverySamples);
    expect(c.state, CoordinatorState.lagging);
    observe(c, _quiet, Coordinator.recoverySamples - 1);
    expect(c.state, CoordinatorState.lagging);
    observe(c, _quiet);
    expect(c.state, CoordinatorState.healthy);
  });

  test('the local channel has no queue and no health: answered while the '
      'coordinator is saturated', () async {
    final c = coordinator(extra: [_Bulk()]);
    observe(c, _stuck);
    expect(c.state, CoordinatorState.saturated);

    final local = LocalCoordinatorChannel(c);
    expect(await local.call('bulk', 'x', {'v': 1}), 1);
    expect(c.deferred, 0);
    expect(c.stats()['shed'], isEmpty);
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
