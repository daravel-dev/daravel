import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';

import '../dartisan_cli.dart';

List<Duration> _parseBackoff(String? raw) => raw == null || raw.trim().isEmpty
    ? const <Duration>[]
    : [for (final s in raw.split(',')) Duration(seconds: int.parse(s.trim()))];

/// `queue:work` — processes jobs until stopped.
final class QueueWorkCommand extends DaravelCommand {
  /// The `dartisan queue:work` command.
  QueueWorkCommand(super.createApp) {
    argParser
      ..addOption('queue', help: 'Comma separated queues in priority order.')
      ..addOption('tries', help: 'Attempts before failing (0 = job default).')
      ..addOption('backoff', help: 'Comma separated retry delays in seconds.')
      ..addOption('timeout', help: 'Per-job timeout in seconds.')
      ..addOption(
        'sleep',
        defaultsTo: '3',
        help: 'Seconds to sleep when empty.',
      )
      ..addOption('max-jobs', help: 'Stop after this many jobs.')
      ..addOption('max-time', help: 'Stop after this many seconds.')
      ..addOption(
        'memory',
        help: 'Stop (exit code 12) once memory use reaches this many MB.',
      )
      ..addFlag(
        'once',
        negatable: false,
        help: 'Process a single job and exit.',
      )
      ..addFlag(
        'stop-when-empty',
        negatable: false,
        help: 'Exit once the queue is empty.',
      );
  }

  @override
  String get name => 'queue:work';

  @override
  String get description => 'Start processing jobs on the queue.';

  @override
  Future<int> run() async {
    final code = await _work();
    if (code == 1) {
      // A restart: a handler given up past its timeout may still hold a
      // timer or a socket that would keep the VM alive, so the process
      // manager would wait for it before starting a fresh worker. The
      // application is shut down already; end the process here.
      await stdout.flush();
      exit(code);
    }
    return code;
  }

  Future<int> _work() => withApp((app) async {
    final r = argResults!;
    final connection = r.rest.isEmpty ? null : r.rest.first;
    final tries = int.tryParse(r['tries'] as String? ?? '');
    final timeout = int.tryParse(r['timeout'] as String? ?? '');
    final maxTime = int.tryParse(r['max-time'] as String? ?? '');
    final memory = int.tryParse(r['memory'] as String? ?? '');
    final options = WorkerOptions(
      connection: connection,
      queues: (r['queue'] as String? ?? 'default')
          .split(',')
          .map((q) => q.trim())
          .where((q) => q.isNotEmpty)
          .toList(),
      tries: tries == null || tries == 0 ? null : tries,
      backoff: r['backoff'] == null
          ? null
          : _parseBackoff(r['backoff'] as String?),
      timeout: timeout == null ? null : Duration(seconds: timeout),
      sleep: Duration(seconds: int.tryParse(r['sleep'] as String) ?? 3),
      maxJobs: r['once'] as bool
          ? 1
          : int.tryParse(r['max-jobs'] as String? ?? ''),
      maxTime: maxTime == null ? null : Duration(seconds: maxTime),
      stopWhenEmpty: r['stop-when-empty'] as bool || r['once'] as bool,
      memory: memory,
    );
    final worker = QueueWorker(App.make<QueueManager>(), logger: app.logger);
    final stopWatching = watchStopSignals(worker.stop);
    final code = await worker.run(options).whenComplete(stopWatching);
    stdout.writeln('Processed ${worker.processed} job(s).');
    return code;
  });
}

/// `queue:failed` — lists failed jobs.
final class QueueFailedCommand extends DaravelCommand {
  /// The `dartisan queue:failed` command.
  QueueFailedCommand(super.createApp);

  @override
  String get name => 'queue:failed';

  @override
  String get description => 'List all of the failed queue jobs.';

  @override
  Future<int> run() => withApp((app) async {
    final failed = await App.make<QueueManager>().processor.failedJobs.all();
    if (failed.isEmpty) {
      stdout.writeln('No failed jobs found.');
      return 0;
    }
    stdout.write(
      renderTable(<List<String>>[
        <String>['ID', 'UUID', 'Connection', 'Queue', 'Failed At', 'Exception'],
        for (final job in failed)
          <String>[
            '${job.id}',
            job.uuid,
            job.connection,
            job.queue,
            job.failedAt.toIso8601String(),
            job.exception.split('\n').first,
          ],
      ]),
    );
    return 0;
  });
}

/// `queue:retry <id|uuid|all> [--queue=name]` — pushes failed jobs back
/// onto the queue.
///
/// `all` (or `--queue`, all of that queue, as in Laravel) reads the failed
/// jobs a page at a time and goes past one whose payload cannot be read: it
/// stays in `failed_jobs`, is printed, and the command ends with 1.
/// `all --queue=name` retries that queue only; Laravel's `all` takes every
/// queue whatever `--queue` says.
final class QueueRetryCommand extends DaravelCommand {
  /// The `dartisan queue:retry` command.
  QueueRetryCommand(super.createApp) {
    argParser.addOption('queue', help: 'Retry every failed job of this queue.');
  }

  @override
  String get name => 'queue:retry';

  @override
  String get description => 'Retry a failed queue job (or `all`).';

  /// How long one locked pass of `all` runs before it lets go of the lock
  /// and goes on from where it stopped.
  static const Duration passBudget = Duration(seconds: 30);

  @override
  Future<int> run() => withApp((app) async {
    final ids = argResults!.rest;
    final queue = argResults!['queue'] as String?;
    if (ids.isEmpty && queue == null) {
      usageException('Provide a failed job id/uuid, `all` or --queue.');
    }
    final manager = App.make<QueueManager>();
    void pushed(FailedJob failed) => stdout.writeln(
      'The failed job [${failed.uuid}] has been pushed back onto the queue.',
    );
    if ((ids.length == 1 && ids.first == 'all') || queue != null) {
      final RetryAllTotals totals;
      try {
        totals = await retryAll(
          manager,
          queue: queue,
          onRetried: pushed,
          onSkipped: (failed, error) => stderr.writeln(
            'The failed job [${failed.uuid}] (id ${failed.id}) cannot be '
            'read and stays in failed_jobs: $error',
          ),
        );
      } on RetryAllRunningException catch (error) {
        stderr.writeln(error.message);
        return 1;
      }
      if (totals.retried == 0 && totals.skipped == 0) {
        stdout.writeln('No failed jobs matched.');
      }
      return totals.skipped == 0 ? 0 : 1;
    }
    var found = false;
    for (final id in ids) {
      final failed = await manager.retryFailed(id);
      if (failed != null) {
        found = true;
        pushed(failed);
      }
    }
    if (!found) {
      stdout.writeln('No failed jobs matched.');
    }
    return 0;
  });

  /// Retries every failed job of [manager] (of [queue] when given), in
  /// locked passes of [passBudget] that go on from where the last one
  /// stopped, up to the last failed job there was at the start. A failed
  /// job provider without pages ([FailedJobPages]) is read once, in a single
  /// pass without a budget: each pass would read all of it again, and on
  /// `sync` a job failing again at once would keep a pass busy for ever.
  static Future<RetryAllTotals> retryAll(
    QueueManager manager, {
    String? queue,
    Duration passBudget = QueueRetryCommand.passBudget,
    void Function(FailedJob failed)? onRetried,
    void Function(FailedJob failed, Object error)? onSkipped,
  }) async {
    final paged = manager.processor.failedJobs is FailedJobPages;
    var retried = 0;
    var skipped = 0;
    var after = 0;
    int? upTo;
    while (true) {
      final result = await manager.retryAllFailed(
        queue: queue,
        budget: paged ? passBudget : null,
        after: after,
        upTo: upTo,
        onRetried: onRetried,
        onSkipped: onSkipped,
      );
      retried += result.retried.length;
      skipped += result.skippedCount;
      if (!paged || result.remaining == 0) {
        break;
      }
      after = result.after;
      upTo = result.upTo;
    }
    return (retried: retried, skipped: skipped);
  }
}

/// How many failed jobs [QueueRetryCommand.retryAll] pushed back and how
/// many it left behind (unreadable).
typedef RetryAllTotals = ({int retried, int skipped});

/// `queue:forget <id>` — deletes a failed job.
final class QueueForgetCommand extends DaravelCommand {
  /// The `dartisan queue:forget` command.
  QueueForgetCommand(super.createApp);

  @override
  String get name => 'queue:forget';

  @override
  String get description => 'Delete a failed queue job.';

  @override
  Future<int> run() => withApp((app) async {
    if (argResults!.rest.isEmpty) {
      usageException('Provide a failed job id/uuid.');
    }
    final removed = await App.make<QueueManager>().processor.failedJobs.forget(
      argResults!.rest.first,
    );
    stdout.writeln(
      removed
          ? 'Failed job deleted successfully.'
          : 'No failed job matches the given ID.',
    );
    return removed ? 0 : 1;
  });
}

/// `queue:flush [--hours=N]` — deletes failed jobs.
final class QueueFlushCommand extends DaravelCommand {
  /// The `dartisan queue:flush` command.
  QueueFlushCommand(super.createApp) {
    argParser.addOption(
      'hours',
      help: 'Only delete entries older than N hours.',
    );
  }

  @override
  String get name => 'queue:flush';

  @override
  String get description => 'Flush all of the failed queue jobs.';

  @override
  Future<int> run() async {
    // A given --hours that is not a whole number above zero deletes
    // nothing: a typo must never widen the flush to every failed job.
    final given = argResults!['hours'] as String?;
    final hours = given == null ? null : int.tryParse(given.trim());
    if (given != null && (hours == null || hours <= 0)) {
      usageException('--hours takes a whole number of hours above 0.');
    }
    return _flush(hours);
  }

  Future<int> _flush(int? hours) => withApp((app) async {
    final provider = App.make<QueueManager>().processor.failedJobs;
    final count = hours == null
        ? await provider.flush()
        : await provider.prune(Duration(hours: hours));
    stdout.writeln('$count failed job(s) deleted.');
    return 0;
  });
}

/// `queue:clear [connection] [--queue=]` — deletes pending jobs.
final class QueueClearCommand extends DaravelCommand {
  /// The `dartisan queue:clear` command.
  QueueClearCommand(super.createApp) {
    argParser.addOption(
      'queue',
      defaultsTo: 'default',
      help: 'Queue to clear.',
    );
    addForceFlag(argParser);
  }

  @override
  String get name => 'queue:clear';

  @override
  String get description => 'Delete all of the jobs from the specified queue.';

  @override
  Future<int> run() => withApp((app) async {
    // As artisan's queue:clear (ConfirmableTrait): --force in production.
    if (refuseInProduction(app, argResults!, 'queue:clear')) {
      return 1;
    }
    final connection = argResults!.rest.isEmpty ? null : argResults!.rest.first;
    final count = await App.make<QueueManager>()
        .connection(connection)
        .clear(argResults!['queue'] as String);
    stdout.writeln('Cleared $count job(s).');
    return 0;
  });
}

/// `queue:restart` — asks running workers to stop after their current job.
/// `[connection:]queue` argument of `queue:pause` / `queue:continue`
/// (Laravel 11 syntax): `default`, `database:emails`.
(String?, String) parseQueueTarget(String? argument) {
  final value = (argument == null || argument.isEmpty) ? 'default' : argument;
  final colon = value.indexOf(':');
  return colon == -1
      ? (null, value)
      : (value.substring(0, colon), value.substring(colon + 1));
}

/// `queue:pause [connection:]queue` — workers stop taking jobs from the
/// queue (running jobs finish) until `queue:continue`.
final class QueuePauseCommand extends DaravelCommand {
  /// The `dartisan queue:pause` command.
  QueuePauseCommand(super.createApp);

  @override
  String get name => 'queue:pause';

  @override
  String get description => 'Pause job processing for a queue.';

  @override
  String get invocation => 'dartisan queue:pause [connection:]queue';

  @override
  Future<int> run() => withApp((app) async {
    final (connection, queue) = parseQueueTarget(argResults!.rest.firstOrNull);
    await App.make<QueueManager>().pause(queue, connection: connection);
    stdout.writeln('Job processing on queue [$queue] has been paused.');
    return 0;
  });
}

/// `queue:continue [connection:]queue` — resumes a paused queue.
final class QueueContinueCommand extends DaravelCommand {
  /// The `dartisan queue:continue` command.
  QueueContinueCommand(super.createApp);

  @override
  String get name => 'queue:continue';

  @override
  String get description => 'Resume job processing for a paused queue.';

  @override
  String get invocation => 'dartisan queue:continue [connection:]queue';

  @override
  Future<int> run() => withApp((app) async {
    final (connection, queue) = parseQueueTarget(argResults!.rest.firstOrNull);
    await App.make<QueueManager>().resume(queue, connection: connection);
    stdout.writeln('Job processing on queue [$queue] has been resumed.');
    return 0;
  });
}

/// Tells the workers to stop after their current job (`queue:restart`).
final class QueueRestartCommand extends DaravelCommand {
  /// The `dartisan queue:restart` command.
  QueueRestartCommand(super.createApp);

  @override
  String get name => 'queue:restart';

  @override
  String get description =>
      'Restart queue worker daemons after their current job.';

  @override
  Future<int> run() => withApp((app) async {
    await App.make<QueueManager>().restart();
    stdout.writeln('Broadcasting queue restart signal.');
    return 0;
  });
}

/// `schedule:run` — runs the tasks due this minute.
final class ScheduleRunCommand extends DaravelCommand {
  /// The `dartisan schedule:run` command.
  ScheduleRunCommand(super.createApp, this.dartisan);

  /// Runs the scheduled commands.
  final DartisanRunner dartisan;

  @override
  String get name => 'schedule:run';

  @override
  String get description => 'Run the scheduled commands that are due.';

  @override
  Future<int> run() => withApp((app) async {
    final results = await app.scheduler(commandRunner: dartisan.runNamed).run();
    if (results.isEmpty) {
      stdout.writeln('No scheduled commands are ready to run.');
    }
    for (final result in results) {
      final status = !result.ran
          ? 'SKIPPED (${result.skipped})'
          : result.error == null
          ? 'DONE'
          : 'FAILED: ${result.error}';
      stdout.writeln('Running [${result.task.name}] ... $status');
    }
    return results.any((r) => r.error != null) ? 1 : 0;
  });
}

/// `schedule:work` — runs the scheduler loop in the foreground.
final class ScheduleWorkCommand extends DaravelCommand {
  /// The `dartisan schedule:work` command.
  ScheduleWorkCommand(super.createApp, this.dartisan);

  /// Runs the scheduled commands.
  final DartisanRunner dartisan;

  @override
  String get name => 'schedule:work';

  @override
  String get description => 'Start the schedule worker (runs every minute).';

  @override
  Future<int> run() async {
    var abandoned = false;
    final code = await withApp((app) async {
      final scheduler = app.scheduler(commandRunner: dartisan.runNamed);
      final stopWatching = watchStopSignals(scheduler.stop);
      stdout.writeln(
        'Schedule worker started (${app.config.section<AppConfig>().env}).',
      );
      await scheduler.work().whenComplete(stopWatching);
      abandoned = scheduler.runningTasks > 0;
      return 0;
    });
    if (abandoned) {
      // Tasks still running after the drain had their locks released: end
      // them with the process rather than let them run on unprotected.
      await stdout.flush();
      exit(code);
    }
    return code;
  }
}

/// `schedule:clear-cache` — releases the overlap locks left behind.
final class ScheduleClearCacheCommand extends DaravelCommand {
  /// The `dartisan schedule:clear-cache` command.
  ScheduleClearCacheCommand(super.createApp);

  @override
  String get name => 'schedule:clear-cache';

  @override
  String get description =>
      'Delete the cached mutex files created by scheduler (the overlap '
      'locks of withoutOverlapping tasks).';

  @override
  Future<int> run() => withApp((app) async {
    final cleared = await app.scheduler().clearCache();
    if (cleared.isEmpty) {
      stdout.writeln('No mutex files were found.');
    }
    for (final task in cleared) {
      stdout.writeln('Deleting mutex for [$task]');
    }
    return 0;
  });
}

/// `schedule:list` — prints the schedule.
final class ScheduleListCommand extends DaravelCommand {
  /// The `dartisan schedule:list` command.
  ScheduleListCommand(super.createApp) {
    argParser.addOption(
      'timezone',
      help: 'Show the next due times in this zone (default UTC).',
    );
  }

  @override
  String get name => 'schedule:list';

  @override
  String get description => 'List all scheduled tasks.';

  @override
  Future<int> run() => withApp((app) async {
    final tasks = App.make<Schedule>().tasks;
    if (tasks.isEmpty) {
      stdout.writeln('No scheduled tasks have been defined.');
      return 0;
    }
    final now = DateTime.now().toUtc();
    final zone = argResults!['timezone'] as String?;
    String due(DateTime? utc) => switch (utc) {
      null => '-',
      final at when zone == null => at.toIso8601String(),
      final at => ScheduledTask.wallTime(
        at,
        zone,
      ).toIso8601String().replaceFirst('Z', ''),
    };
    stdout.write(
      renderTable(<List<String>>[
        <String>[
          'Expression',
          'Zone',
          'Task',
          'Next Due (${zone ?? 'UTC'})',
          'Options',
        ],
        for (final task in tasks)
          <String>[
            task.cron.expression,
            task.timezoneName,
            task.name,
            due(task.nextRun(now)),
            [
              if (task.overlapProtected) 'withoutOverlapping',
              if (task.singleServer) 'onOneServer',
              if (task.runsInBackground) 'background',
            ].join(', '),
          ],
      ]),
    );
    return 0;
  });
}

/// Calls [stop] on `SIGINT` and, outside Windows, `SIGTERM` (sent by
/// systemd, Docker, Kubernetes and Cloud Run), so long-running workers
/// finish the current job before exiting. Returns a function that removes
/// the handlers.
Future<void> Function() watchStopSignals(void Function() stop) {
  final subscriptions = <StreamSubscription<ProcessSignal>>[
    ProcessSignal.sigint.watch().listen((_) => stop()),
    if (!Platform.isWindows)
      ProcessSignal.sigterm.watch().listen((_) => stop()),
  ];
  return () => Future.wait([for (final s in subscriptions) s.cancel()]);
}
