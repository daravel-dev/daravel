import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

final String dbPath =
    '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_cmd_$pid.sqlite';
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
      // Blocks the worker's event loop: no heartbeat, the lease runs out.
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(seconds: 20)) {}
    }
    File(marksPath).writeAsStringSync('$label\n', mode: FileMode.append);
  }
}

Application cmdApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'sqlite',
          'DB_DATABASE': dbPath,
          'QUEUE_CONNECTION': 'database',
          'CACHE_STORE': 'file',
          'QUEUE_SIGNAL_STORE': 'database',
          'HORIZON_HEARTBEAT_MS': '100',
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

  setUp(() async {
    for (final path in [dbPath, marksPath]) {
      if (File(path).existsSync()) {
        File(path).deleteSync();
      }
    }
    app = cmdApp();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
  });

  tearDown(() => app.shutdown());

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
}
