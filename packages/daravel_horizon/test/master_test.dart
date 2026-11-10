import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

final String dbPath =
    '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_master_$pid.sqlite';
final String marksPath =
    '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_master_marks_$pid.txt';

/// Blocks its isolate's event loop (no heartbeat) on its first attempt.
final class Hang extends Job {
  const Hang(this.label, {this.ms = 0});
  factory Hang.fromJson(Map<String, Object?> json) =>
      Hang(json['label']! as String, ms: (json['ms'] as num?)?.toInt() ?? 0);
  final String label;
  final int ms;
  @override
  String get jobName => 'hang';
  @override
  int get tries => 3;
  @override
  Map<String, Object?> toJson() => {'label': label, 'ms': ms};
  @override
  Future<void> handle(JobContext ctx) async {
    if (label == 'boom') {
      // Brings its worker down on every attempt.
      Isolate.current.kill(priority: Isolate.immediate);
      await Completer<void>().future;
    }
    if (label == 'hang' && ctx.attempt == 1) {
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 20)) {}
    }
    await Future<void>.delayed(Duration(milliseconds: ms));
    File(marksPath).writeAsStringSync(
      '${ctx.queue}:$label:${ctx.attempt}\n',
      mode: FileMode.append,
    );
  }
}

Application masterApp() => Application.configure(basePath: _basePath())
    .withEnv({
      'APP_ENV': 'testing',
      'DB_CONNECTION': 'sqlite',
      'DB_DATABASE': dbPath,
      'QUEUE_CONNECTION': 'database',
      'CACHE_STORE': 'file',
    })
    .withLogLevel(LogLevel.error)
    .withMigrations(const [CreateJobsTable(), CreateCacheTable()])
    .withJobs([JobDefinition('hang', Hang.fromJson)])
    .create();

List<String> marks() =>
    File(marksPath).existsSync() ? File(marksPath).readAsLinesSync() : const [];

Future<void> until(
  bool Function() done,
  String what, {
  int seconds = 30,
}) async {
  final deadline = DateTime.now().add(Duration(seconds: seconds));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  late Application app;
  final events = <(String, Map<String, Object?>)>[];

  setUp(() async {
    events.clear();
    for (final path in [dbPath, marksPath]) {
      if (File(path).existsSync()) {
        File(path).deleteSync();
      }
    }
    app = masterApp();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
  });

  tearDown(() => app.shutdown());

  // The process's coordinator with Horizon's store, shared with the
  // workers (as `withCoordinatorService` registers it).
  late Coordinator coordinator;
  setUp(
    () => coordinator = createStandardCoordinator()..register(HorizonService()),
  );
  tearDown(() => coordinator.close());

  HorizonMaster master(SupervisorPlan plan) => HorizonMaster(
    masterApp,
    HorizonConfig(
      plans: [plan],
      heartbeat: const Duration(milliseconds: 100),
      // A short target wait, so a backlog of 20 ms jobs needs workers.
      waits: const {'database:a': Duration(seconds: 1)},
    ),
    driver: (connection) =>
        app.container.make<QueueManager>().connection(connection),
    logger: Logger(minimumLevel: LogLevel.critical),
    coordinator: coordinator.listen(),
    store: LocalCoordinatorChannel(coordinator),
    failedJobs: app.container.make<QueueManager>().processor.failedJobs,
    onEvent: (event, data) => events.add((event, data)),
    crashDelay: (_) => const Duration(milliseconds: 50),
  );

  test(
    'a backlog scales the pool up, at most balanceMaxShift at a time',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await app.run(() async {
        for (var i = 0; i < 300; i++) {
          await Queue.push(Hang('j$i', ms: 20), queue: 'a');
        }
      });
      final m = master(
        const SupervisorPlan(
          name: SupervisorName('s'),
          queues: [QueueName('a')],
          maxProcesses: 3,
          balanceMaxShift: 2,
          balanceCooldown: Duration(milliseconds: 300),
          sleep: Duration(milliseconds: 50),
        ),
      );
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      await until(() => m.workers('s').length == 3, 'three workers');
      final ups = [
        for (final (event, data) in events)
          if (event == 'SupervisorLooped' && data['reason'] == 'scale-up')
            (data['before']! as int, data['after']! as int),
      ];
      expect(ups.first, (1, 3));
      var left = 300;
      final poll = Timer.periodic(const Duration(milliseconds: 200), (_) async {
        left = await app.run(() => Queue.size('a'));
      });
      addTearDown(poll.cancel);
      await until(() => left == 0, 'an empty queue', seconds: 90);
      await m.stop(timeout: const Duration(seconds: 20));
      expect(m.workers('s'), isEmpty);
      // The workers recorded every job in the store, and the master read
      // the rates from it.
      final service =
          coordinator.service(HorizonService.serviceName)! as HorizonService;
      expect(service.stats()['completed'], 300);
      expect(service.rates('a')['avg_ms'], greaterThanOrEqualTo(20));
    },
  );

  test(
    'a worker that stops answering is killed and its job reclaimed at '
    'once',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await app.run(() => Queue.push(const Hang('hang'), queue: 'a'));
      final m = master(
        const SupervisorPlan(
          name: SupervisorName('s'),
          queues: [QueueName('a')],
          balance: BalanceStrategy.off,
          maxProcesses: 1,
          sleep: Duration(milliseconds: 50),
        ),
      );
      final watch = Stopwatch()..start();
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      await until(
        () => marks().contains('a:hang:2'),
        'attempt 2 on a new worker',
      );
      // retry_after is 90 s: only the reclaim brings it back this soon.
      expect(watch.elapsed, lessThan(const Duration(seconds: 30)));
      final killed = [
        for (final (event, data) in events)
          if (event == 'WorkerKilled') data,
      ];
      expect(killed.single['reason'], 'lease');
      expect(killed.single['job'], isNotNull);
      await m.stop(timeout: const Duration(seconds: 20));
    },
  );

  test(
    'a job that brings its worker down twice is quarantined in failed_jobs',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      await app.run(() => Queue.push(const Hang('boom'), queue: 'a'));
      final m = master(
        const SupervisorPlan(
          name: SupervisorName('s'),
          queues: [QueueName('a')],
          balance: BalanceStrategy.off,
          maxProcesses: 1,
          sleep: Duration(milliseconds: 50),
        ),
      );
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      await until(
        () => events.any((e) => e.$1 == 'JobQuarantined'),
        'the quarantine',
      );
      final failed = await app.run(
        () => App.make<QueueManager>().processor.failedJobs.all(),
      );
      expect(failed, hasLength(1));
      expect(failed.single.exception, contains('JobQuarantinedException'));
      expect(failed.single.queue, 'a');
      expect(await app.run(() => Queue.size('a')), 0);
      final quarantined = events.firstWhere((e) => e.$1 == 'JobQuarantined');
      expect(quarantined.$2['crashes'], 2);
      await m.stop(timeout: const Duration(seconds: 20));
    },
  );

  test(
    'horizon:pause, continue and terminate reach it through the signal store',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final signals = app.container.make<QueueManager>().signalStore;
      final m = HorizonMaster(
        masterApp,
        HorizonConfig(
          plans: const [
            SupervisorPlan(
              name: SupervisorName('s'),
              queues: [QueueName('a')],
              balance: BalanceStrategy.off,
              maxProcesses: 1,
              sleep: Duration(milliseconds: 50),
            ),
          ],
          heartbeat: const Duration(milliseconds: 100),
        ),
        driver: (c) => app.container.make<QueueManager>().connection(c),
        logger: Logger(minimumLevel: LogLevel.critical),
        signals: signals,
      );
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      // A command from before it started is not its own.
      await HorizonSignals.send(signals, 'horizon', 'terminate');
      await m.start();
      await until(() => m.workers('s').any((w) => w.ready), 'a ready worker');

      await HorizonSignals.send(signals, 'horizon', 'pause');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      await app.run(() => Queue.push(const Hang('while-paused'), queue: 'a'));
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(marks(), isEmpty);

      await HorizonSignals.send(signals, 'horizon', 'continue');
      await until(() => marks().isNotEmpty, 'the job after continue');

      await HorizonSignals.send(signals, 'horizon', 'terminate');
      await until(() => m.workers('s').isEmpty, 'every worker gone');
    },
  );

  test(
    'past HORIZON_MEMORY_LIMIT workers are replaced one at a time',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final m = HorizonMaster(
        masterApp,
        HorizonConfig(
          plans: const [
            SupervisorPlan(
              name: SupervisorName('s'),
              queues: [QueueName('a')],
              balance: BalanceStrategy.off,
              maxProcesses: 2,
              sleep: Duration(milliseconds: 50),
            ),
          ],
          heartbeat: const Duration(milliseconds: 100),
          memoryLimit: 1, // MB: always past it
        ),
        driver: (c) => app.container.make<QueueManager>().connection(c),
        logger: Logger(minimumLevel: LogLevel.critical),
        onEvent: (event, data) => events.add((event, data)),
      );
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      final first = {for (final w in m.workers('s')) w.name};
      await until(
        () => events.where((e) => e.$2['reason'] == 'memory').length >= 2,
        'two recycles',
      );
      await until(
        () => m.workers('s').where((w) => !w.stopping).length == 2,
        'two live workers',
      );
      final now = {for (final w in m.workers('s')) w.name};
      expect(now.difference(first), isNotEmpty, reason: 'fresh workers');
      // Never more than one recycled at a time.
      expect(
        m.workers('s').where((w) => w.recycling).length,
        lessThanOrEqualTo(1),
      );
    },
  );

  test(
    'pauseSupervisor pauses one supervisor only',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final m = HorizonMaster(
        masterApp,
        HorizonConfig(
          plans: const [
            SupervisorPlan(
              name: SupervisorName('one'),
              queues: [QueueName('a')],
              balance: BalanceStrategy.off,
              maxProcesses: 1,
              sleep: Duration(milliseconds: 50),
            ),
            SupervisorPlan(
              name: SupervisorName('two'),
              queues: [QueueName('b')],
              balance: BalanceStrategy.off,
              maxProcesses: 1,
              sleep: Duration(milliseconds: 50),
            ),
          ],
          heartbeat: const Duration(milliseconds: 100),
        ),
        driver: (c) => app.container.make<QueueManager>().connection(c),
        logger: Logger(minimumLevel: LogLevel.critical),
      );
      addTearDown(() => m.stop(timeout: const Duration(seconds: 20)));
      await m.start();
      await until(
        () => [...m.workers('one'), ...m.workers('two')].every((w) => w.ready),
        'ready workers',
      );
      m.pauseSupervisor('one');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await app.run(() async {
        await Queue.push(const Hang('held'), queue: 'a');
        await Queue.push(const Hang('free'), queue: 'b');
      });
      await until(() => marks().contains('b:free:1'), 'the other supervisor');
      expect(marks(), isNot(contains('a:held:1')));
      m.resumeSupervisor('one');
      await until(() => marks().contains('a:held:1'), 'after continue');
    },
  );
}

/// This file's own directory, by name and pid: the master and its worker
/// isolates share it (the file signal store, Horizon's status), and test
/// files running in parallel do not.
String _basePath() => (Directory(
  '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_master_base_$pid',
)..createSync(recursive: true)).path;
