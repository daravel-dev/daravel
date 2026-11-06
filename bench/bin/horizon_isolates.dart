// What Horizon's worker isolates cost (Blueprint #134 H3, item 8).
//
// ```bash
// dart run bin/horizon_isolates.dart                     # JIT
// dart build cli -t bin/horizon_isolates.dart -o build/horizon_isolates
// build/horizon_isolates/bundle/bin/horizon_isolates     # AOT
// ```
//
// For 1, 4 and 8 worker isolates of one supervisor on a SQLite file queue:
// the time from `HorizonMaster.start` until every worker is ready (spawn +
// boot of its application), and the process's resident memory idle and
// while the workers run a backlog of short jobs. Isolates share one heap,
// so the memory is the process's, not a worker's. Only numbers this prints
// may be quoted in the README or the docs.
import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';

final String _db =
    '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_bench_$pid.sqlite';

final class _Work extends Job {
  const _Work();
  @override
  String get jobName => 'work';
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) =>
      Future<void>.delayed(const Duration(milliseconds: 5));
}

Application _app() => Application.configure(basePath: Directory.systemTemp.path)
    .withEnv({
      'APP_ENV': 'testing',
      'DB_CONNECTION': 'sqlite',
      'DB_DATABASE': _db,
      'QUEUE_CONNECTION': 'database',
      'CACHE_STORE': 'file',
    })
    .withLogLevel(LogLevel.critical)
    .withMigrations(const [CreateJobsTable(), CreateCacheTable()])
    .withJobs([JobDefinition('work', (_) => const _Work())])
    .create();

Future<int> _rss() async {
  // A few samples a moment apart; the median damps a GC in flight.
  final samples = <int>[];
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    samples.add(ProcessInfo.currentRss);
  }
  samples.sort();
  return samples[samples.length ~/ 2];
}

String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

Future<void> main() async {
  if (File(_db).existsSync()) {
    File(_db).deleteSync();
  }
  final app = _app();
  await app.boot();
  await app.run(() => App.make<Migrator>().run());
  final queues = app.container.make<QueueManager>();
  final base = await _rss();
  stdout
    ..writeln(
      'Dart ${Platform.version.split(' ').first}, '
      '${Platform.operatingSystem}, ${Platform.numberOfProcessors} CPUs',
    )
    ..writeln('process RSS before any worker: ${_mb(base)} MB')
    ..writeln('')
    ..writeln('| workers | spawn + boot (all ready) | RSS idle | RSS busy |')
    ..writeln('| --: | --: | --: | --: |');
  for (final count in const [1, 4, 8]) {
    final master = HorizonMaster(
      _app,
      HorizonConfig(
        plans: [
          SupervisorPlan(
            name: const SupervisorName('bench'),
            queues: const [QueueName('bench')],
            balance: BalanceStrategy.off,
            maxProcesses: count,
            sleep: const Duration(milliseconds: 100),
          ),
        ],
        heartbeat: const Duration(milliseconds: 200),
      ),
      driver: queues.connection,
      logger: Logger(minimumLevel: LogLevel.critical),
    );
    final watch = Stopwatch()..start();
    await master.start();
    while (master.workers('bench').where((w) => w.ready).length < count) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final ready = watch.elapsed;
    final idle = await _rss();
    await app.run(() async {
      for (var i = 0; i < count * 200; i++) {
        await Queue.push(const _Work(), queue: 'bench');
      }
    });
    final busy = await _rss();
    while (await app.run(() => Queue.size('bench')) > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await master.stop();
    stdout.writeln(
      '| $count | ${ready.inMilliseconds} ms | ${_mb(idle)} MB | ${_mb(busy)} MB |',
    );
    await Future<void>.delayed(const Duration(seconds: 1));
  }
  await app.shutdown();
  File(_db).deleteSync();
}
