import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

/// The workers' application: top-level, as the master's factory must be.
Application timersApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'QUEUE_CONNECTION': 'memory',
        })
        .withLogLevel(LogLevel.critical)
        .create();

/// A queue whose sizes answer only once [hold] completes: an evaluation
/// slower than the balance cooldown.
final class _HeldDriver implements QueueDriver {
  Completer<void>? hold;
  int sizes = 0;

  @override
  String get name => 'held';

  @override
  Future<int> size(String queue) async {
    sizes++;
    await hold?.future;
    return 1000;
  }

  @override
  Future<Duration?> oldestWait(String queue) async =>
      const Duration(minutes: 5);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A signal store whose reads answer only once [hold] completes, and that
/// counts them.
final class _HeldStore implements CacheStore {
  final Map<String, Object?> values = {};
  Completer<void>? hold;
  int reads = 0;

  @override
  StateScope get scope => StateScope.process;

  @override
  Future<Object?> get(String key) async {
    reads++;
    await hold?.future;
    return values[key];
  }

  @override
  Future<void> forever(String key, Object? value) async => values[key] = value;

  @override
  Future<void> put(String key, Object? value, {Duration? ttl}) async =>
      values[key] = value;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Counts the snapshots the master asks its store for.
final class _CountingChannel implements CoordinatorChannel {
  int snapshots = 0;

  @override
  StateScope get scope => StateScope.process;

  @override
  bool get isRemote => false;

  @override
  Future<Object?> call(
    String service,
    String op,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 1),
  }) async {
    if (op == 'snapshot') {
      snapshots++;
    }
    return op == 'rates' ? '{"per_second":0,"avg_ms":null}' : null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> until(bool Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// What happens when the work of a periodic timer takes longer than its
/// period: a second run must not start beside the first (Review #148, #153).
void main() {
  test('a balance slower than its cooldown does not overlap the next one: '
      'the pool never grows past maxProcesses', () async {
    final driver = _HeldDriver();
    const plan = SupervisorPlan(
      name: SupervisorName('s'),
      queues: [QueueName('a')],
      balance: BalanceStrategy.auto,
      minProcesses: 1,
      maxProcesses: 4,
      balanceMaxShift: 4,
      balanceCooldown: Duration(milliseconds: 50),
      sleep: Duration(milliseconds: 50),
    );
    final master = HorizonMaster(
      timersApp,
      const HorizonConfig(plans: [plan], heartbeat: Duration(seconds: 1)),
      driver: (_) => driver,
      logger: Logger(minimumLevel: LogLevel.critical),
      store: _CountingChannel(),
    );
    addTearDown(() => master.stop(timeout: const Duration(seconds: 20)));
    // The first evaluation, at start, is let through.
    await master.start();
    // Then every evaluation waits on the queue for several cooldowns.
    driver.hold = Completer<void>();
    final before = driver.sizes;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(
      driver.sizes - before,
      1,
      reason: 'one evaluation at a time, however many cooldowns pass',
    );
    driver.hold!.complete();
    driver.hold = null;
    await Future<void>.delayed(const Duration(milliseconds: 500));
    await until(
      () => master.workers('s').every((w) => w.ready),
      'the workers ready',
    );
    expect(
      master.workers('s').where((w) => !w.stopping),
      hasLength(lessThanOrEqualTo(4)),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('two evaluations resizing at once never spawn past the target: the '
      'live workers are counted again on each spawn', () async {
    final driver = _HeldDriver();
    const plan = SupervisorPlan(
      name: SupervisorName('s'),
      queues: [QueueName('a')],
      balance: BalanceStrategy.auto,
      minProcesses: 1,
      maxProcesses: 4,
      balanceMaxShift: 4,
      // No periodic evaluation during the test: only the two below.
      balanceCooldown: Duration(hours: 1),
      sleep: Duration(milliseconds: 50),
    );
    final master = HorizonMaster(
      timersApp,
      const HorizonConfig(plans: [plan], heartbeat: Duration(seconds: 1)),
      driver: (_) => driver,
      logger: Logger(minimumLevel: LogLevel.critical),
      store: _CountingChannel(),
    );
    addTearDown(() => master.stop(timeout: const Duration(seconds: 20)));
    await master.start();
    expect(master.workers('s'), hasLength(1));
    // Both read the queue (held), so both decide from one worker.
    driver.hold = Completer<void>();
    final both = Future.wait([master.balance(plan), master.balance(plan)]);
    await until(() => driver.sizes >= 2, 'both evaluations reading');
    driver.hold!.complete();
    driver.hold = null;
    await both;
    expect(
      master.workers('s').where((w) => !w.stopping),
      hasLength(4),
      reason: 'the target, not more',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a poll slower than its second does not run a command twice', () async {
    final signals = _HeldStore();
    final channel = _CountingChannel();
    final master = HorizonMaster(
      timersApp,
      const HorizonConfig(
        plans: [
          SupervisorPlan(
            name: SupervisorName('s'),
            queues: [QueueName('a')],
            minProcesses: 0,
            maxProcesses: 1,
          ),
        ],
        heartbeat: Duration(seconds: 1),
      ),
      driver: (_) => _HeldDriver(),
      logger: Logger(minimumLevel: LogLevel.critical),
      store: channel,
      signals: CacheRepository(signals),
    );
    addTearDown(() => master.stop(timeout: const Duration(seconds: 20)));
    await master.start();
    // Reads now wait for several poll periods.
    signals.hold = Completer<void>();
    await HorizonSignals.send(CacheRepository(signals), 'horizon', 'snapshot');
    final readsBefore = signals.reads;
    await Future<void>.delayed(const Duration(milliseconds: 3500));
    expect(signals.reads - readsBefore, 1, reason: 'one poll at a time');
    signals.hold!.complete();
    signals.hold = null;
    await until(() => channel.snapshots > 0, 'the snapshot');
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(channel.snapshots, 1, reason: 'the command ran once');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
