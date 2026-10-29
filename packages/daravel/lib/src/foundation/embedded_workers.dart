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
/// never blocks the HTTP event loop. A crashed isolate is respawned with a
/// growing delay; more than five crashes in a minute stop the respawning.
/// [stop] asks each isolate to finish its current job or tick and waits up
/// to the shutdown timeout before killing it.
///
/// [Application.serveWith] manages it; custom entrypoints can use it too.
final class EmbeddedWorkers {
  EmbeddedWorkers(
    this.factory, {
    required this.roles,
    required this.logger,
    this.commandRunner,
    this.coordinator,
  });

  final ApplicationFactory factory;
  final List<EmbeddedRole> roles;
  final Logger logger;
  ScheduleCommandRunner? commandRunner;

  /// The server's coordinator (`Coordinator.listen()`), so the embedded
  /// isolates share its `process` cache store, rate limits and locks with
  /// the HTTP workers: a token a job revokes is refused by the server, a
  /// limit a scheduled task raises holds for the next request. Without it
  /// each isolate has a coordinator of its own.
  final SendPort? coordinator;

  final Map<EmbeddedRole, _EmbeddedIsolate> _running = {};
  final Map<EmbeddedRole, List<DateTime>> _crashes = {};
  bool _stopping = false;

  static const int _maxCrashesPerMinute = 5;

  Future<void> start() async {
    for (final role in roles) {
      await _spawn(role);
    }
  }

  Future<void> _spawn(EmbeddedRole role) async {
    final control = ReceivePort();
    final exit = ReceivePort();
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
        onExit: exit.sendPort,
        debugName: 'daravel-${role.name}',
      );
    } on ArgumentError catch (error) {
      if (commandRunner == null) {
        control.close();
        exit.close();
        rethrow;
      }
      // The CLI's command runner could not be sent to the isolate.
      logger.warning(
        'Scheduled commands are unavailable in the embedded scheduler: '
        '$error',
      );
      commandRunner = null;
      control.close();
      exit.close();
      return _spawn(role);
    }
    final inbox = Completer<SendPort>();
    var crashed = false;
    control.listen((message) {
      if (message is SendPort && !inbox.isCompleted) {
        inbox.complete(message);
      } else if (message == 'crashed') {
        crashed = true;
      }
    });
    final done = Completer<void>();
    exit.listen((_) {
      control.close();
      exit.close();
      _running.remove(role);
      done.complete();
      if (!_stopping) {
        if (crashed) {
          logger.error('Embedded ${role.name} isolate crashed; respawning.');
        }
        _respawn(role);
      }
    });
    _running[role] = _EmbeddedIsolate(isolate, inbox.future, done.future);
    logger.info('Embedded ${role.name} isolate started.');
  }

  void _respawn(EmbeddedRole role) {
    final now = DateTime.now();
    final recent = (_crashes[role] ??= [])
      ..removeWhere((t) => now.difference(t) > const Duration(minutes: 1))
      ..add(now);
    if (recent.length > _maxCrashesPerMinute) {
      logger.error(
        'Embedded ${role.name} isolate exited ${recent.length} times in a '
        'minute; not respawning it. Run `dartisan '
        '${role == EmbeddedRole.queue ? 'queue:work' : 'schedule:work'}` to '
        'see the error.',
      );
      return;
    }
    Timer(Duration(seconds: recent.length), () {
      if (!_stopping) {
        unawaited(_spawn(role));
      }
    });
  }

  /// Asks every isolate to stop after its current job or tick; kills the
  /// ones still running after [timeout].
  Future<void> stop({Duration timeout = const Duration(seconds: 30)}) async {
    _stopping = true;
    final running = _running.values.toList();
    for (final embedded in running) {
      (await embedded.inbox).send('stop');
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
  final app = start.factory();
  if (start.coordinator case final port?) {
    app.coordinator = RemoteCoordinatorChannel(port);
  }
  var outcome = 'stopped';
  try {
    await app.boot();
    await app.run<void>(() async {
      switch (start.role) {
        case EmbeddedRole.queue:
          final worker = QueueWorker(
            app.container.make<QueueManager>(),
            logger: app.logger,
          );
          inbox.listen((_) => worker.stop());
          final queues =
              app.env.maybeString('SERVER_EMBED_QUEUES') ??
              app.config.section<QueueConfig>().defaultQueue;
          await worker.run(
            WorkerOptions(
              queues: [
                for (final queue in queues.split(','))
                  if (queue.trim().isNotEmpty) queue.trim(),
              ],
            ),
          );
        case EmbeddedRole.scheduler:
          final scheduler = app.scheduler(commandRunner: start.commands);
          inbox.listen((_) => scheduler.stop());
          await scheduler.work();
      }
    }, scope: 'job');
  } catch (error, stackTrace) {
    outcome = 'crashed';
    try {
      app.logger.error(
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
      await app.shutdown();
    } catch (_) {
      // Already reported, or nothing to release.
    }
  }
  Isolate.exit(start.control, outcome);
}
