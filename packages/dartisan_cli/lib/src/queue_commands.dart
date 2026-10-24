import 'dart:io';

import 'package:daravel/daravel.dart';

import '../dartisan_cli.dart';

List<Duration> _parseBackoff(String? raw) => raw == null || raw.trim().isEmpty
    ? const <Duration>[]
    : [for (final s in raw.split(',')) Duration(seconds: int.parse(s.trim()))];

/// `queue:work` — processes jobs until stopped.
final class QueueWorkCommand extends DaravelCommand {
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
  Future<int> run() => withApp((app) async {
    final r = argResults!;
    final connection = r.rest.isEmpty ? null : r.rest.first;
    final tries = int.tryParse(r['tries'] as String? ?? '');
    final timeout = int.tryParse(r['timeout'] as String? ?? '');
    final maxTime = int.tryParse(r['max-time'] as String? ?? '');
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
    );
    final worker = QueueWorker(App.make<QueueManager>(), logger: app.logger);
    ProcessSignal.sigint.watch().listen((_) => worker.stop());
    final code = await worker.run(options);
    stdout.writeln('Processed ${worker.processed} job(s).');
    return code;
  });
}

/// `queue:failed` — lists failed jobs.
final class QueueFailedCommand extends DaravelCommand {
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

/// `queue:retry <id|uuid|all>` — pushes failed jobs back onto the queue.
final class QueueRetryCommand extends DaravelCommand {
  QueueRetryCommand(super.createApp);

  @override
  String get name => 'queue:retry';

  @override
  String get description => 'Retry a failed queue job (or `all`).';

  @override
  Future<int> run() => withApp((app) async {
    final ids = argResults!.rest;
    if (ids.isEmpty) {
      usageException('Provide a failed job id/uuid or `all`.');
    }
    final manager = App.make<QueueManager>();
    final provider = manager.processor.failedJobs;
    final targets = ids.length == 1 && ids.first == 'all'
        ? await provider.all()
        : [for (final id in ids) ?await provider.find(id)];
    for (final failed in targets) {
      final payload = JobPayload.decode(failed.payload);
      await manager
          .connection(failed.connection)
          .push(
            JobPayload.fromJson(<String, Object?>{
              ...payload.toJson(),
              'uniqueKey': null,
            }),
            queue: failed.queue,
          );
      await provider.forget(failed.id);
      stdout.writeln(
        'The failed job [${failed.uuid}] has been pushed back onto the queue.',
      );
    }
    if (targets.isEmpty) {
      stdout.writeln('No failed jobs matched.');
    }
    return 0;
  });
}

/// `queue:forget <id>` — deletes a failed job.
final class QueueForgetCommand extends DaravelCommand {
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
  Future<int> run() => withApp((app) async {
    final provider = App.make<QueueManager>().processor.failedJobs;
    final hours = int.tryParse(argResults!['hours'] as String? ?? '');
    final count = hours == null
        ? await provider.flush()
        : await provider.prune(Duration(hours: hours));
    stdout.writeln('$count failed job(s) deleted.');
    return 0;
  });
}

/// `queue:clear [connection] [--queue=]` — deletes pending jobs.
final class QueueClearCommand extends DaravelCommand {
  QueueClearCommand(super.createApp) {
    argParser.addOption(
      'queue',
      defaultsTo: 'default',
      help: 'Queue to clear.',
    );
  }

  @override
  String get name => 'queue:clear';

  @override
  String get description => 'Delete all of the jobs from the specified queue.';

  @override
  Future<int> run() => withApp((app) async {
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

final class QueueRestartCommand extends DaravelCommand {
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
  ScheduleRunCommand(super.createApp, this.dartisan);

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
  ScheduleWorkCommand(super.createApp, this.dartisan);

  final DartisanRunner dartisan;

  @override
  String get name => 'schedule:work';

  @override
  String get description => 'Start the schedule worker (runs every minute).';

  @override
  Future<int> run() => withApp((app) async {
    final scheduler = app.scheduler(commandRunner: dartisan.runNamed);
    ProcessSignal.sigint.watch().listen((_) => scheduler.stop());
    stdout.writeln(
      'Schedule worker started (${app.config.section<AppConfig>().env}).',
    );
    await scheduler.work();
    return 0;
  });
}

/// `schedule:list` — prints the schedule.
final class ScheduleListCommand extends DaravelCommand {
  ScheduleListCommand(super.createApp);

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
    stdout.write(
      renderTable(<List<String>>[
        <String>['Expression', 'Task', 'Next Due (UTC)', 'Options'],
        for (final task in tasks)
          <String>[
            task.cron.expression,
            task.name,
            task.nextRun(now)?.toIso8601String() ?? '-',
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
