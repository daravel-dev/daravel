import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';

import 'config.dart';
import 'master.dart';
import 'routes.dart';
import 'setup.dart' show HorizonRoutes, horizonKillPolicy;
import 'signals.dart';
import 'store/process_store.dart';

/// The `horizon:*` commands, for `bootstrap/commands.dart`:
///
/// ```dart
/// final List<CommandFactory> commands = [...horizonCommands];
/// ```
const List<CommandFactory> horizonCommands = [
  HorizonCommand.new,
  HorizonStatusCommand.new,
  HorizonListCommand.new,
  HorizonSupervisorsCommand.new,
  HorizonPauseCommand.new,
  HorizonContinueCommand.new,
  HorizonPauseSupervisorCommand.new,
  HorizonContinueSupervisorCommand.new,
  HorizonTerminateCommand.new,
  HorizonClearCommand.new,
  HorizonForgetCommand.new,
  HorizonSnapshotCommand.new,
];

/// `horizon:snapshot`: the running Horizon takes a metric snapshot (per job
/// and queue; the dashboard's Metrics tab). Schedule it every five
/// minutes, as Laravel Horizon's.
final class HorizonSnapshotCommand extends _SignalCommand {
  /// The `dartisan horizon:snapshot` command.
  HorizonSnapshotCommand(super.createApp);

  @override
  String get name => 'horizon:snapshot';

  @override
  String get description => 'Stores a snapshot of the queue metrics.';

  @override
  String get command => 'snapshot';

  @override
  String get done => 'Sent snapshot to Horizon.';
}

String _name(Application app) =>
    app.config.section<HorizonConfig>().name ?? 'horizon';

CacheRepository? _signals(Application app) =>
    app.container.make<QueueManager>().signalStore;

/// `horizon`: runs the supervisors in this process until `SIGINT`,
/// `SIGTERM` or `horizon:terminate`, as Laravel's `php artisan horizon`.
/// For one process serving HTTP and queues, use `serve --embed-worker=horizon`
/// instead.
final class HorizonCommand extends DaravelCommand {
  /// The `dartisan horizon` command.
  HorizonCommand(super.createApp) {
    argParser.addOption(
      'dashboard',
      valueHelp: '[host]:port',
      help:
          'Also serve the dashboard (and only it) on this address, for a '
          'Horizon that runs apart from the HTTP server (`:8090`).',
    );
  }

  /// `host:port` or `:port` (the host then `127.0.0.1`); null when not an
  /// address.
  static (String, int)? parseAddress(String value) {
    final colon = value.lastIndexOf(':');
    final port = int.tryParse(value.substring(colon + 1));
    if (colon < 0 || port == null || port < 0 || port > 65535) {
      return null;
    }
    final host = value.substring(0, colon);
    return (host.isEmpty ? '127.0.0.1' : host, port);
  }

  /// A server answering only the dashboard's routes of [app], on [host]
  /// and [port], with the application's middleware and error pages.
  static Future<ServerEngine> serveDashboard(
    Application app, {
    required String host,
    required int port,
  }) async {
    final routes = app.container.make<HorizonRoutes>();
    final router = Router();
    HorizonDashboard.routes(
      router,
      path: routes.path,
      middleware: routes.middleware,
    );
    router.compile(app.kernel.middleware);
    final engine = ServerEngine(
      app,
      ServeOptions(host: host, port: port, handleSignals: false),
      kernel: HttpKernel(
        router: router,
        middleware: app.kernel.middleware,
        exceptions: app.kernel.exceptions,
        logger: app.logger,
      ),
      logger: app.logger,
    );
    await engine.start();
    return engine;
  }

  @override
  String get name => 'horizon';

  @override
  String get description =>
      'Runs the Horizon supervisors and their worker isolates.';

  @override
  Future<int> run() => withApp((app) async {
    final config = app.config.section<HorizonConfig>();
    if (!config.enabled) {
      stderr.writeln('Horizon is disabled (HORIZON_ENABLED=false).');
      return 1;
    }
    final dashboard = argResults!['dashboard'] as String?;
    final address = dashboard == null ? null : parseAddress(dashboard);
    if (dashboard != null && address == null) {
      usageException('--dashboard takes [host]:port, such as :8090.');
    }
    final queues = app.container.make<QueueManager>();
    final channel = app.container.make<CoordinatorChannel>();
    final done = Completer<void>();
    final policy = await horizonKillPolicy(app);
    final sqlite = policy.restartAfterKill == 'sqlite_lock';
    var code = 0;
    if (sqlite) {
      stderr.writeln('Warning: ${HorizonConfig.sqliteWarning}');
    }
    final master = HorizonMaster(
      createApp,
      config,
      driver: queues.connection,
      logger: app.logger,
      coordinator: channel is LocalCoordinatorChannel
          ? channel.coordinator.listen()
          : null,
      store: channel,
      failedJobs: queues.processor.failedJobs,
      signals: queues.signalStore,
      name: _name(app),
      onTerminate: () {
        if (!done.isCompleted) {
          done.complete();
        }
      },
      restartAfterKill: policy.restartAfterKill,
      terminateSession: policy.terminate,
      workerIdleTransactionTimeout: policy.idleTransactionTimeout,
      onRestartNeeded: () {
        // EX_TEMPFAIL: restart this process, which frees the locks.
        code = 75;
        if (!done.isCompleted) {
          done.complete();
        }
      },
    );
    await master.start();
    stdout.writeln(
      'Horizon started: ${[for (final p in config.plans) p.name.value].join(', ')}.',
    );
    ServerEngine? server;
    if (address case (final host, final port)) {
      server = await serveDashboard(app, host: host, port: port);
      stdout.writeln(
        'Dashboard: http://$host:${server.port}'
        '${app.container.make<HorizonRoutes>().path}',
      );
    }
    final signals = [
      ProcessSignal.sigint.watch(),
      if (!Platform.isWindows) ProcessSignal.sigterm.watch(),
    ];
    final subscriptions = [
      for (final signal in signals)
        signal.listen((_) {
          if (!done.isCompleted) {
            done.complete();
          }
        }),
    ];
    await done.future;
    for (final s in subscriptions) {
      await s.cancel();
    }
    await server?.stop();
    await master.stop(
      timeout: code == 75 ? config.killGrace : const Duration(seconds: 30),
    );
    stdout.writeln(
      code == 75
          ? 'Horizon stopped after a kill that left database locks; exiting 75 '
                'for a restart.'
          : 'Horizon stopped.',
    );
    return code;
  });
}

/// `horizon:status`: running, paused or inactive.
final class HorizonStatusCommand extends DaravelCommand {
  /// The `dartisan horizon:status` command.
  HorizonStatusCommand(super.createApp);

  @override
  String get name => 'horizon:status';

  @override
  String get description => 'Shows whether Horizon is running.';

  @override
  Future<int> run() => withApp((app) async {
    final state = await HorizonSignals.status(_signals(app), _name(app));
    final value = state['state'];
    stdout.writeln('Horizon is $value.');
    if (HorizonConfig.onSqliteFile(app.config)) {
      stdout.writeln('Warning: ${HorizonConfig.sqliteWarning}');
    }
    return value == 'inactive' ? 1 : 0;
  });
}

/// `horizon:list`: the worker isolates and what they poll.
final class HorizonListCommand extends DaravelCommand {
  /// The `dartisan horizon:list` command.
  HorizonListCommand(super.createApp);

  @override
  String get name => 'horizon:list';

  @override
  String get description => 'Lists the Horizon worker isolates.';

  @override
  Future<int> run() => withApp((app) async {
    final state = await HorizonSignals.status(_signals(app), _name(app));
    final supervisors = (state['supervisors'] as Map<String, Object?>?) ?? {};
    if (state['state'] == 'inactive' || supervisors.isEmpty) {
      stdout.writeln('No Horizon workers are running.');
      return 0;
    }
    for (final MapEntry(key: plan, value: workers) in supervisors.entries) {
      for (final w
          in (workers! as List<Object?>).cast<Map<String, Object?>>()) {
        stdout.writeln(
          '${w['name']}  $plan  [${w['queues']}]  '
          '${w['processed']} processed${w['busy'] == true ? ', busy' : ''}'
          '${w['stopping'] == true ? ', stopping' : ''}',
        );
      }
    }
    return 0;
  });
}

/// `horizon:supervisors`: each supervisor and its worker count.
final class HorizonSupervisorsCommand extends DaravelCommand {
  /// The `dartisan horizon:supervisors` command.
  HorizonSupervisorsCommand(super.createApp);

  @override
  String get name => 'horizon:supervisors';

  @override
  String get description => 'Lists the Horizon supervisors.';

  @override
  Future<int> run() => withApp((app) async {
    final config = app.config.section<HorizonConfig>();
    final state = await HorizonSignals.status(_signals(app), _name(app));
    if (HorizonConfig.onSqliteFile(app.config)) {
      stdout.writeln('Warning: ${HorizonConfig.sqliteWarning}');
    }
    final running = (state['supervisors'] as Map<String, Object?>?) ?? {};
    for (final plan in config.plans) {
      final workers = (running[plan.name.value] as List<Object?>?) ?? const [];
      stdout.writeln(
        '${plan.name.value}  [${[for (final q in plan.queues) q.value].join(', ')}]  '
        '${workers.length} of ${plan.minProcesses}..${plan.maxProcesses} '
        'workers  ${plan.balance.name}  (${state['state']})',
      );
    }
    return 0;
  });
}

abstract base class _SignalCommand extends DaravelCommand {
  _SignalCommand(super.createApp);

  String get command;

  String get done;

  @override
  Future<int> run() => withApp((app) async {
    final store = _signals(app);
    if (!await HorizonSignals.send(store, _name(app), command)) {
      stderr.writeln('No signal store (QUEUE_SIGNAL_STORE) to reach Horizon.');
      return 1;
    }
    stdout.writeln(done);
    return after(app, store);
  });

  Future<int> after(Application app, CacheRepository? store) async => 0;
}

/// `horizon:pause`: every worker stops taking jobs.
final class HorizonPauseCommand extends _SignalCommand {
  /// The `dartisan horizon:pause` command.
  HorizonPauseCommand(super.createApp);

  @override
  String get name => 'horizon:pause';

  @override
  String get description => 'Pauses the Horizon workers.';

  @override
  String get command => 'pause';

  @override
  String get done => 'Sent pause to Horizon.';
}

/// `horizon:continue`: workers take jobs again.
final class HorizonContinueCommand extends _SignalCommand {
  /// The `dartisan horizon:continue` command.
  HorizonContinueCommand(super.createApp);

  @override
  String get name => 'horizon:continue';

  @override
  String get description => 'Lets paused Horizon workers take jobs again.';

  @override
  String get command => 'continue';

  @override
  String get done => 'Sent continue to Horizon.';
}

/// `horizon:terminate [--wait]`: the workers finish their jobs and Horizon
/// stops; with `--wait`, until it is inactive.
final class HorizonTerminateCommand extends _SignalCommand {
  /// The `dartisan horizon:terminate` command.
  HorizonTerminateCommand(super.createApp) {
    argParser.addFlag(
      'wait',
      negatable: false,
      help: 'Waits until every worker has finished.',
    );
  }

  @override
  String get name => 'horizon:terminate';

  @override
  String get description => 'Stops Horizon once its workers finish.';

  @override
  String get command => 'terminate';

  @override
  String get done => 'Sent terminate to Horizon.';

  @override
  Future<int> after(Application app, CacheRepository? store) async {
    if (!(argResults!['wait'] as bool)) {
      return 0;
    }
    final deadline = DateTime.now().add(const Duration(minutes: 10));
    while (DateTime.now().isBefore(deadline)) {
      final state = await HorizonSignals.status(store, _name(app));
      final supervisors = (state['supervisors'] as Map<String, Object?>?) ?? {};
      final left = supervisors.values.fold<int>(
        0,
        (sum, workers) => sum + (workers! as List<Object?>).length,
      );
      if (state['state'] == 'inactive' && left == 0) {
        stdout.writeln('Horizon is inactive.');
        return 0;
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    stderr.writeln('Horizon did not stop within 10 minutes.');
    return 1;
  }
}

/// `horizon:clear [--queue=default] [--connection=]`: deletes every job of
/// a queue (Laravel's `horizon:clear`).
final class HorizonClearCommand extends DaravelCommand {
  /// The `dartisan horizon:clear` command.
  HorizonClearCommand(super.createApp) {
    argParser
      ..addOption('queue', defaultsTo: 'default', help: 'The queue to clear.')
      ..addOption('connection', help: 'The queue connection.')
      ..addFlag('force', negatable: false, help: 'Clear in production.');
  }

  @override
  String get name => 'horizon:clear';

  @override
  String get description => 'Deletes every job of a queue.';

  @override
  Future<int> run() => withApp((app) async {
    if (app.config.section<AppConfig>().isProduction &&
        !(argResults!['force'] as bool)) {
      stderr.writeln('In production, pass --force to clear a queue.');
      return 1;
    }
    final queue = argResults!['queue']! as String;
    final driver = app.container.make<QueueManager>().connection(
      argResults!['connection'] as String?,
    );
    final count = await driver.clear(queue);
    stdout.writeln('Cleared $count jobs from [$queue] on [${driver.name}].');
    return 0;
  });
}

/// `horizon:forget {id} | --all`: deletes failed jobs (Laravel's
/// `horizon:forget`).
final class HorizonForgetCommand extends DaravelCommand {
  /// The `dartisan horizon:forget` command.
  HorizonForgetCommand(super.createApp) {
    argParser.addFlag('all', negatable: false, help: 'Every failed job.');
  }

  @override
  String get name => 'horizon:forget';

  @override
  String get description => 'Deletes a failed job, or all of them.';

  @override
  Future<int> run() => withApp((app) async {
    final failed = app.container.make<QueueManager>().processor.failedJobs;
    if (argResults!['all'] as bool) {
      stdout.writeln('Deleted ${await failed.flush()} failed jobs.');
      return 0;
    }
    final rest = argResults!.rest;
    if (rest.isEmpty) {
      usageException('Pass the id (or uuid) of a failed job, or --all.');
    }
    final forgotten = await failed.forget(rest.first);
    stdout.writeln(
      forgotten
          ? 'Failed job ${rest.first} deleted.'
          : 'No failed job ${rest.first}.',
    );
    return forgotten ? 0 : 1;
  });
}

/// The recent jobs of [status] in the store of [app], newest first.
Future<List<RecordedJob>> recentJobs(Application app, String status) async {
  final raw = await app.container.make<CoordinatorChannel>().call(
    HorizonService.serviceName,
    'recent',
    {'status': status},
  );
  return [
    for (final job in (jsonDecodeList(raw! as String)))
      RecordedJob.fromJson(job),
  ];
}

/// [text] as a list of JSON objects.
List<Map<String, Object?>> jsonDecodeList(String text) => [
  for (final item in (const JsonDecoder().convert(text) as List<Object?>))
    item! as Map<String, Object?>,
];

/// The supervisor named by the first argument, checked against the plans.
String _supervisorArgument(DaravelCommand command, Application app) {
  final rest = command.argResults!.rest;
  if (rest.isEmpty) {
    command.usageException('Pass the name of a supervisor.');
  }
  final plans = [
    for (final p in app.config.section<HorizonConfig>().plans) p.name.value,
  ];
  if (!plans.contains(rest.first)) {
    command.usageException(
      'No supervisor [${rest.first}] (supervisors: ${plans.join(', ')}).',
    );
  }
  return rest.first;
}

/// `horizon:pause-supervisor {name}`: the workers of one supervisor stop
/// taking jobs.
final class HorizonPauseSupervisorCommand extends DaravelCommand {
  /// The `dartisan horizon:pause-supervisor` command.
  HorizonPauseSupervisorCommand(super.createApp);

  @override
  String get name => 'horizon:pause-supervisor';

  @override
  String get description => 'Pauses the workers of one Horizon supervisor.';

  @override
  Future<int> run() => withApp((app) async {
    final plan = _supervisorArgument(this, app);
    if (!await HorizonSignals.send(
      _signals(app),
      _name(app),
      'pause-supervisor:$plan',
    )) {
      stderr.writeln('No signal store (QUEUE_SIGNAL_STORE) to reach Horizon.');
      return 1;
    }
    stdout.writeln('Sent pause to supervisor [$plan].');
    return 0;
  });
}

/// `horizon:continue-supervisor {name}`: one paused supervisor takes jobs
/// again.
final class HorizonContinueSupervisorCommand extends DaravelCommand {
  /// The `dartisan horizon:continue-supervisor` command.
  HorizonContinueSupervisorCommand(super.createApp);

  @override
  String get name => 'horizon:continue-supervisor';

  @override
  String get description => 'Lets a paused Horizon supervisor take jobs again.';

  @override
  Future<int> run() => withApp((app) async {
    final plan = _supervisorArgument(this, app);
    if (!await HorizonSignals.send(
      _signals(app),
      _name(app),
      'continue-supervisor:$plan',
    )) {
      stderr.writeln('No signal store (QUEUE_SIGNAL_STORE) to reach Horizon.');
      return 1;
    }
    stdout.writeln('Sent continue to supervisor [$plan].');
    return 0;
  });
}
