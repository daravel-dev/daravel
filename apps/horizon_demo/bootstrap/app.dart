import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:horizon_demo/jobs/demo_jobs.dart';

import '../routes/console.dart';
import '../routes/web.dart';

/// Detects the application's base path when run from the repository root
/// or the package folder.
String _resolveBasePath() {
  final current = Directory.current.path;
  final candidate = Directory(
    Platform.isWindows
        ? '$current\\apps\\horizon_demo'
        : '$current/apps/horizon_demo',
  );
  return candidate.existsSync() ? candidate.path : current;
}

/// Two supervisors: `web` scales `default` by how long its jobs wait,
/// `reports` keeps one worker.
const List<SupervisorPlan> plans = [
  SupervisorPlan(
    name: SupervisorName('web'),
    queues: [QueueName('default')],
    minProcesses: 1,
    maxProcesses: 4,
  ),
  SupervisorPlan(
    name: SupervisorName('reports'),
    queues: [QueueName('reports')],
    balance: BalanceStrategy.off,
    maxProcesses: 1,
  ),
];

/// Builds the unbooted application; each Horizon worker isolate builds its
/// own with it. Outside `APP_ENV=local` the dashboard answers 403 until the
/// `viewHorizon` gate or `HorizonDashboard.auth` allows the request (see the
/// README).
Application createApp({String? basePath, Map<String, String>? env}) =>
    Application.configure(basePath: basePath ?? _resolveBasePath())
        .withEnv(env ?? const <String, String>{})
        .withRouting(web: webRoutes, health: '/up')
        .withMigrations(const [CreateJobsTable()])
        .withJobs(jobs)
        .withSchedule(consoleRoutes)
        .withHorizon(createApp: createApp, plans: plans)
        .create();
