// The Daravel side of bench/interop/horizon.sh: Daravel's Horizon beside
// Laravel Horizon on one Redis (REDIS_PREFIX shared) and one PostgreSQL.
//
//   horizon_interop dispatch <n>     push n jobs to the `daravel` queue
//   horizon_interop serve            the dashboard (APP_PORT)
//   horizon_interop <dartisan args>  `horizon`, `horizon:clear`, ...
import 'dart:io';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/commands.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:dartisan_cli/dartisan_cli.dart';

/// One supervisor on the `daravel` queue only; Laravel Horizon works
/// `default`.
const List<SupervisorPlan> plans = [
  SupervisorPlan(
    name: SupervisorName('daravel'),
    queues: [QueueName('daravel')],
    balance: BalanceStrategy.off,
    minProcesses: 2,
    maxProcesses: 2,
  ),
];

/// Records which side ran it: `interop_runs` (source, job, worker).
final class InteropJob extends Job {
  const InteropJob(this.n);

  factory InteropJob.fromJson(Map<String, Object?> json) =>
      InteropJob((json['n']! as num).toInt());

  final int n;

  @override
  String get jobName => 'interop';

  @override
  Map<String, Object?> toJson() => {'n': n};

  @override
  Future<void> handle(JobContext ctx) async {
    await DB.table('interop_runs').insert({
      'source': 'daravel',
      'job': n,
      'worker': 'daravel-${Isolate.current.debugName}-$pid',
    });
  }
}

Application createApp({String? basePath, Map<String, String>? env}) =>
    Application.configure(basePath: basePath ?? Directory.current.path)
        .withEnv(env ?? const <String, String>{})
        .withRedis()
        .withJobs([JobDefinition('interop', InteropJob.fromJson)])
        .withRouting(web: (router) {}, health: '/up')
        .withHorizon(createApp: createApp, plans: plans)
        .create();

Future<void> main(List<String> args) async {
  switch (args.firstOrNull) {
    case 'dispatch':
      final app = createApp();
      await app.boot();
      final count = int.parse(args[1]);
      await app.run(() async {
        for (var i = 0; i < count; i++) {
          await Queue.push(InteropJob(i), queue: 'daravel');
        }
      });
      await app.shutdown();
      stdout.writeln('dispatched=$count');
    case 'serve':
      exitCode = await Application.serveWith(createApp);
    default:
      exitCode = await DartisanRunner(
        createApp,
        commands: horizonCommands,
      ).execute(args);
  }
}
