part of 'application.dart';

/// What an embedded isolate runs next to the HTTP server.
enum EmbeddedRole {
  /// `queue:work` on `SERVER_EMBED_QUEUES` (default: the default queue).
  queue,

  /// `schedule:work`.
  scheduler,
}

/// Queue worker and scheduler isolates started by [Application.serveWith]
/// (`serve --embed-queue --embed-scheduler`), so one process can serve HTTP,
/// process jobs and run the schedule without supervisord or cron.
///
/// Each role runs its own application in its own isolate, so a slow job
/// never blocks the HTTP event loop. An isolate that ends on its own (a
/// queue worker restarting after `queue:restart` or a timed-out job) is
/// started again at once. One that crashes is started again after
/// [crashDelay]: a second per crash in the last minute, and a minute
/// between attempts, each logged as an error, once there were more than
/// [maxCrashesPerMinute]; it is never given up while the server runs.
/// Uncaught asynchronous errors inside an isolate are logged, not fatal.
/// [stop] asks each isolate to finish its current job or tick and waits up
/// to the shutdown timeout before killing it.
///
/// [Application.serveWith] manages it; custom entrypoints can use it too.
final class EmbeddedWorkers {
  /// Runs the [roles] (queue worker, scheduler) of applications from
  /// [factory] beside the HTTP server.
  EmbeddedWorkers(
    this.factory, {
    required this.roles,
    required this.logger,
    this.commandRunner,
    this.coordinator,
    this.crashDelay = defaultCrashDelay,
  });

  /// Builds each role's application.
  final ApplicationFactory factory;

  /// The roles run.
  final List<EmbeddedRole> roles;

  /// Logs starts, crashes and stops.
  final Logger logger;

  /// Runs the scheduled commands.
  ScheduleCommandRunner? commandRunner;

  /// The server's coordinator (`Coordinator.listen()`), so the embedded
  /// isolates share its `process` cache store, rate limits and locks with
  /// the HTTP workers: a token a job revokes is refused by the server, a
  /// limit a scheduled task raises holds for the next request. Without it
  /// each isolate has a coordinator of its own.
  final SendPort? coordinator;

  /// The wait before starting a role again after its isolate crashed, given
  /// how many times it crashed in the last minute ([defaultCrashDelay]).
  final Duration Function(int crashes) crashDelay;

  final Map<EmbeddedRole, _EmbeddedIsolate> _running = {};
  final Map<EmbeddedRole, List<DateTime>> _crashes = {};
  bool _stopping = false;

  /// Crashes in a minute beyond which a role is started only once a minute.
  static const int maxCrashesPerMinute = 5;

  /// A second per crash in the last minute; a minute past
  /// [maxCrashesPerMinute].
  static Duration defaultCrashDelay(int crashes) =>
      crashes > maxCrashesPerMinute
      ? const Duration(minutes: 1)
      : Duration(seconds: crashes);

  /// Starts every role in its own isolate.
  Future<void> start() async {
    for (final role in roles) {
      await _spawn(role);
    }
  }

  Future<void> _spawn(EmbeddedRole role) async {
    // One port for the isolate's messages and its exit: they arrive in the
    // order they were sent, so the outcome is known when the exit is.
    final control = ReceivePort();
    final Isolate isolate;
    try {
      isolate = await Isolate.spawn(
        _embeddedMain,
        _EmbeddedStart(
          factory,
          role,
          control.sendPort,
          commandRunner,
          coordinator,
        ),
        onExit: control.sendPort,
        debugName: 'daravel-${role.name}',
      );
    } on ArgumentError catch (error) {
      if (commandRunner == null) {
        control.close();
        rethrow;
      }
      // The CLI's command runner could not be sent to the isolate.
      logger.warning(
        'Scheduled commands are unavailable in the embedded scheduler: '
        '$error',
      );
      commandRunner = null;
      control.close();
      return _spawn(role);
    }
    final inbox = Completer<SendPort>();
    // Until the isolate says otherwise (it ended on its own), an exit is a
    // crash: an isolate killed by an error sends nothing.
    var outcome = _EmbeddedOutcome.crashed;
    final done = Completer<void>();
    control.listen((message) {
      if (message is SendPort) {
        if (!inbox.isCompleted) {
          inbox.complete(message);
        }
      } else if (message is String) {
        outcome = _EmbeddedOutcome.values.byName(message);
      } else if (message == null) {
        control.close();
        _running.remove(role);
        done.complete();
        if (!_stopping) {
          _exited(role, outcome);
        }
      }
    });
    _running[role] = _EmbeddedIsolate(isolate, inbox.future, done.future);
    logger.info('Embedded ${role.name} isolate started.');
  }

  void _exited(EmbeddedRole role, _EmbeddedOutcome outcome) {
    if (outcome == _EmbeddedOutcome.stopped) {
      // A restart the worker asked for (queue:restart, a timed-out job):
      // not a crash, and not counted against the role.
      logger.info('Embedded ${role.name} isolate ended; starting it again.');
      unawaited(_spawn(role));
      return;
    }
    final now = DateTime.now();
    final recent = (_crashes[role] ??= [])
      ..removeWhere((t) => now.difference(t) > const Duration(minutes: 1))
      ..add(now);
    final delay = crashDelay(recent.length);
    final command = role == EmbeddedRole.queue ? 'queue:work' : 'schedule:work';
    logger.error(
      recent.length > maxCrashesPerMinute
          ? 'Embedded ${role.name} isolate crashed ${recent.length} times in '
                'a minute; starting it again in ${delay.inSeconds}s. Run '
                '`dartisan $command` to see the error.'
          : 'Embedded ${role.name} isolate crashed; starting it again in '
                '${delay.inSeconds}s.',
    );
    Timer(delay, () {
      if (!_stopping) {
        unawaited(_spawn(role));
      }
    });
  }

  /// Asks every isolate to stop after its current job or tick (the
  /// scheduler waits up to three quarters of [timeout] for its running
  /// tasks); kills the ones still running after [timeout].
  Future<void> stop({Duration timeout = const Duration(seconds: 30)}) async {
    _stopping = true;
    final running = _running.values.toList();
    for (final embedded in running) {
      // Three quarters of the time left, for the scheduler to wait on the
      // tasks under way and release their locks before it is killed.
      (await embedded.inbox).send(timeout.inMilliseconds * 3 ~/ 4);
    }
    await Future.wait(running.map((e) => e.done)).timeout(
      timeout,
      onTimeout: () {
        for (final embedded in _running.values) {
          logger.warning('Embedded isolate did not stop in time; killing it.');
          embedded.isolate.kill(priority: Isolate.immediate);
        }
        return const <void>[];
      },
    );
  }
}

/// How an embedded isolate ended, as it reports it before exiting.
enum _EmbeddedOutcome {
  /// On its own: stopped, or a restart the worker asked for.
  stopped,

  /// With an error.
  crashed,
}

final class _EmbeddedIsolate {
  _EmbeddedIsolate(this.isolate, this.inbox, this.done);

  final Isolate isolate;
  final Future<SendPort> inbox;
  final Future<void> done;
}

final class _EmbeddedStart {
  const _EmbeddedStart(
    this.factory,
    this.role,
    this.control,
    this.commands,
    this.coordinator,
  );

  final ApplicationFactory factory;
  final EmbeddedRole role;
  final SendPort control;
  final ScheduleCommandRunner? commands;
  final SendPort? coordinator;
}

Future<void> _embeddedMain(_EmbeddedStart start) async {
  final inbox = ReceivePort();
  start.control.send(inbox.sendPort);
  var outcome = _EmbeddedOutcome.stopped;
  Application? app;
  try {
    app = start.factory();
    if (start.coordinator case final port?) {
      app.coordinator = RemoteCoordinatorChannel(port);
    }
    final booted = app;
    await booted.boot();
    // A fire-and-forget error (a listener, a background task, a lock
    // release) is logged; it used to end the isolate in the middle of a
    // job and count as a crash.
    await booted.container.runScoped<void>(
      'job',
      (_) async {
        switch (start.role) {
          case EmbeddedRole.queue:
            final worker = QueueWorker(
              booted.container.make<QueueManager>(),
              logger: booted.logger,
            );
            inbox.listen((_) => worker.stop());
            final queues =
                booted.env.maybeString('SERVER_EMBED_QUEUES') ??
                booted.config.section<QueueConfig>().defaultQueue;
            await worker.run(
              WorkerOptions(
                queues: [
                  for (final queue in queues.split(','))
                    if (queue.trim().isNotEmpty) queue.trim(),
                ],
              ),
            );
          case EmbeddedRole.scheduler:
            final scheduler = booted.scheduler(commandRunner: start.commands);
            inbox.listen(
              (message) => scheduler.stop(
                drain: message is int
                    ? Duration(milliseconds: message)
                    : Scheduler.defaultDrain,
              ),
            );
            await scheduler.work();
        }
      },
      onUncaughtError: (error, stackTrace) => booted.logger.error(
        'Uncaught asynchronous error in the embedded ${start.role.name} '
        'isolate',
        error: error,
        stackTrace: stackTrace,
      ),
    );
  } catch (error, stackTrace) {
    outcome = _EmbeddedOutcome.crashed;
    try {
      app!.logger.error(
        'Embedded ${start.role.name} failed',
        error: error,
        stackTrace: stackTrace,
      );
    } catch (_) {
      stderr.writeln('Embedded ${start.role.name} failed: $error');
    }
  } finally {
    inbox.close();
    try {
      await app?.shutdown();
    } catch (_) {
      // Already reported, or nothing to release.
    }
  }
  Isolate.exit(start.control, outcome.name);
}
