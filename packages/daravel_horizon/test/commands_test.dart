import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/commands.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

final String _temp = '${Directory.systemTemp.path}${Platform.pathSeparator}';

/// The database of the current test, kept in a file every isolate reads (a
/// top-level initializer runs again in each worker isolate). One per test:
/// a test that kills a worker on SQLite leaves the file open in this
/// process until it ends (why `dartisan horizon` then exits 75), and on
/// Windows the next test could not delete it.
final String _dbMarker = '${_temp}horizon_cmd_db_$pid.txt';

String get dbPath {
  final marker = File(_dbMarker);
  return marker.existsSync()
      ? marker.readAsStringSync()
      : '${_temp}horizon_cmd_$pid.sqlite';
}

final String marksPath =
    '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_cmd_marks_$pid.txt';

final class Tick extends Job {
  const Tick(this.label);
  factory Tick.fromJson(Map<String, Object?> json) =>
      Tick(json['label']! as String);
  final String label;
  @override
  String get jobName => 'tick';
  @override
  Map<String, Object?> toJson() => {'label': label};
  @override
  Future<void> handle(JobContext ctx) async {
    if (label == 'hang' && ctx.attempt == 1) {
      // Blocks the worker's event loop past its timeout (2 s): the master
      // kills the worker.
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 20)) {}
    }
    File(marksPath).writeAsStringSync('$label\n', mode: FileMode.append);
  }
}

Application cmdApp() => Application.configure(basePath: _basePath())
    .withEnv({
      'APP_ENV': 'testing',
      'DB_CONNECTION': 'sqlite',
      'DB_DATABASE': dbPath,
      'QUEUE_CONNECTION': 'database',
      'CACHE_STORE': 'file',
      'QUEUE_SIGNAL_STORE': 'database',
      'HORIZON_HEARTBEAT_MS': '100',
      'HORIZON_KILL_GRACE': '1',
    })
    .withLogLevel(LogLevel.error)
    .withMigrations(const [CreateJobsTable(), CreateCacheTable()])
    .withJobs([JobDefinition('tick', Tick.fromJson)])
    .withHorizon(
      createApp: cmdApp,
      plans: const [
        SupervisorPlan(
          name: SupervisorName('supervisor-1'),
          queues: [QueueName('a')],
          balance: BalanceStrategy.off,
          maxProcesses: 1,
          timeout: Duration(seconds: 2),
          sleep: Duration(milliseconds: 50),
        ),
      ],
    )
    .create();

Future<int?> dartisan(List<String> args) {
  final runner = CommandRunner<int>('dartisan', 'test');
  for (final factory in horizonCommands) {
    runner.addCommand(factory(cmdApp));
  }
  return runner.run(args);
}

List<String> marks() =>
    File(marksPath).existsSync() ? File(marksPath).readAsLinesSync() : const [];

Future<void> until(bool Function() done, String what) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for $what');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  late Application app;

  var tests = 0;
  setUp(() async {
    File(_dbMarker)
        .writeAsStringSync('${_temp}horizon_cmd_${pid}_${++tests}.sqlite');
    for (final path in [dbPath, marksPath]) {
      if (File(path).existsSync()) {
        File(path).deleteSync();
      }
    }
    app = cmdApp();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
  });

  tearDown(() async {
    await app.shutdown();
    try {
      File(dbPath).deleteSync();
    } on FileSystemException {
      // A killed worker may still hold it; the temporary directory's own
      // cleanup takes it.
    }
  });
  tearDownAll(() {
    try {
      File(_dbMarker).deleteSync();
    } on FileSystemException {
      // Already gone.
    }
  });

  test('a status the store holds that is not a state: the commands report '
      'Horizon inactive instead of failing', () async {
    final signals = app.container.make<QueueManager>().signalStore!;
    final key = HorizonSignals.statusKey('horizon');
    for (final value in [
      'not json',
      '[1, 2]',
      '"text"',
      '{"at": "yesterday"}',
      '{"state": 5}',
      '{"supervisors": [1]}',
      '{"timedOut": 5}',
    ]) {
      await signals.store.forever(key, value);
      expect(
        (await HorizonSignals.status(signals, 'horizon'))['state'],
        'inactive',
        reason: value,
      );
      for (final command in [
        ['horizon:status'],
        ['horizon:list'],
        ['horizon:supervisors'],
        ['horizon:terminate', '--wait'],
      ]) {
        await expectLater(
          dartisan(command),
          completion(isA<int>()),
          reason: '$command with $value',
        );
      }
    }
  });

  test('horizon:list marks a busy worker that does not report as running a '
      'job that blocks it, and lists the jobs killed past their timeout', () {
    final lines = horizonWorkerLines({
      'state': 'running',
      'supervisors': {
        's': [
          {'name': 'horizon-s-1', 'queues': 'a', 'processed': 3, 'busy': true},
          {
            'name': 'horizon-s-2',
            'queues': 'a',
            'processed': 0,
            'busy': true,
            'silentMs': 7400,
          },
        ],
      },
      'timedOut': [
        {
          'name': 'Report',
          'job': 'u-1',
          'attempt': 2,
          'limitSeconds': 70,
          'worker': 'horizon-s-3',
        },
      ],
    });
    expect(lines, [
      'horizon-s-1  s  [a]  3 processed, busy',
      'horizon-s-2  s  [a]  0 processed, busy (not reporting for 7s: a job '
          'blocking its isolate)',
      'Killed past their timeout (latest last):',
      '  Report u-1 attempt 2, limit 70s, on horizon-s-3',
    ]);
  });

  test(
    'horizon runs the workers until horizon:terminate; status, list and '
    'supervisors read it from another command',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      expect(await dartisan(['horizon:status']), 1, reason: 'inactive');
      final running = dartisan(['horizon']);
      await app.run(() => Queue.push(const Tick('t1'), queue: 'a'));
      await until(() => marks().contains('t1'), 'the job');
      expect(await dartisan(['horizon:status']), 0);
      expect(await dartisan(['horizon:list']), 0);
      expect(await dartisan(['horizon:supervisors']), 0);
      final signals = app.container.make<QueueManager>().signalStore;
      expect(
        (await HorizonSignals.status(signals, 'horizon'))['state'],
        'running',
      );

      expect(await dartisan(['horizon:pause']), 0);
      expect((await HorizonSignals.read(signals, 'horizon'))?.$1, 'pause');
      expect(await dartisan(['horizon:continue']), 0);
      expect((await HorizonSignals.read(signals, 'horizon'))?.$1, 'continue');

      expect(await dartisan(['horizon:terminate', '--wait']), 0);
      expect(await running.timeout(const Duration(seconds: 30)), 0);
      expect(await dartisan(['horizon:status']), 1);
    },
  );

  test(
    'horizon:clear empties a queue; horizon:forget deletes failed jobs',
    () async {
      await app.run(() async {
        await Queue.push(const Tick('x'), queue: 'b');
        await Queue.push(const Tick('y'), queue: 'b');
        await Queue.manager.processor.failedJobs.log(
          connection: 'database',
          queue: 'b',
          payload: JobPayload.forJob(const Tick('z')).encode(),
          exception: 'boom',
        );
      });
      expect(await dartisan(['horizon:clear', '--queue=b']), 0);
      expect(await app.run(() => Queue.size('b')), 0);
      expect(await dartisan(['horizon:forget', '--all']), 0);
      expect(
        await app.run(() => Queue.manager.processor.failedJobs.all()),
        isEmpty,
      );
    },
  );

  test(
    'on SQLite, a killed worker makes horizon drain and exit 75 for a '
    'restart',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final running = dartisan(['horizon']);
      await app.run(() => Queue.push(const Tick('hang'), queue: 'a'));
      expect(await running.timeout(const Duration(seconds: 60)), 75);
      expect(await dartisan(['horizon:status']), 1, reason: 'inactive now');
    },
  );

  test(
    'horizon:pause-supervisor and continue-supervisor name a supervisor',
    () async {
      final signals = app.container.make<QueueManager>().signalStore;
      expect(await dartisan(['horizon:pause-supervisor', 'supervisor-1']), 0);
      expect(
        (await HorizonSignals.read(signals, 'horizon'))?.$1,
        'pause-supervisor:supervisor-1',
      );
      expect(
        await dartisan(['horizon:continue-supervisor', 'supervisor-1']),
        0,
      );
      expect(
        (await HorizonSignals.read(signals, 'horizon'))?.$1,
        'continue-supervisor:supervisor-1',
      );
      await expectLater(
        dartisan(['horizon:pause-supervisor', 'nope']),
        throwsA(isA<UsageException>()),
      );
    },
  );
}

/// This file's own directory, by name and pid: the master and its worker
/// isolates share it (the file signal store, Horizon's status), and test
/// files running in parallel do not.
String _basePath() => (Directory(
  '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_cmd_base_$pid',
)..createSync(recursive: true)).path;
