import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../cache/stores.dart';
import '../foundation/application.dart';
import '../http/rate_limiter.dart';
import '../http/server_engine.dart';
import '../logging/logger.dart';
import '../observability/metrics.dart';
import 'broadcast.dart';
import 'channels.dart';
import 'coordinator.dart';

/// Creates an unbooted [Application]. Must be a top-level function (or a
/// closure capturing nothing) so it can be sent to worker isolates.
typedef ApplicationFactory = Application Function();

/// Builds the standard coordinator: rate limiting, process cache, merged
/// metrics (with the coordinator's own counters), broadcast fan-out and
/// channel membership.
Coordinator createStandardCoordinator() {
  final coordinator = Coordinator();
  return coordinator
    ..register(RateLimitService())
    ..register(ProcessCacheService())
    ..register(MetricsService(coordinatorStats: coordinator.stats))
    ..register(BroadcastService())
    ..register(ChannelMembershipService());
}

/// Sent by a worker once its server is bound.
final class WorkerReady {
  const WorkerReady(this.index, this.port, this.control);

  final int index;
  final int port;
  final SendPort control;
}

/// Sent by a worker that failed to boot or bind.
final class WorkerFailed {
  const WorkerFailed(this.index, this.error);

  final int index;
  final String error;
}

/// Sent by a worker after draining.
final class WorkerDrained {
  const WorkerDrained(this.index);

  final int index;
}

final class _WorkerSpawn {
  const _WorkerSpawn({
    required this.index,
    required this.factory,
    required this.options,
    required this.coordinator,
    required this.supervisor,
  });

  final int index;
  final ApplicationFactory factory;
  final ServeOptions options;
  final SendPort coordinator;
  final SendPort supervisor;
}

final class _Worker {
  _Worker(this.index);

  final int index;
  Isolate? isolate;
  SendPort? control;
  int? port;
  bool drained = false;
  ReceivePort? exitPort;
  ReceivePort? errorPort;
}

/// Main-isolate supervisor (ADR-004): spawns N HTTP workers that bind the
/// same port with `shared: true`, hosts the [Coordinator] for
/// `process`-scope state, waits for readiness, respawns crashed workers
/// with backoff and orchestrates a graceful drain on signals.
final class Supervisor {
  Supervisor(
    this.factory,
    this.options, {
    Logger? logger,
    Coordinator? coordinator,
    this.maxCrashesPerMinute = 5,
  }) : logger = logger ?? Logger(),
       coordinator = coordinator ?? createStandardCoordinator();

  final ApplicationFactory factory;
  final ServeOptions options;
  final Logger logger;
  final Coordinator coordinator;

  /// Crash-loop threshold: beyond this the supervisor exits with code 1.
  final int maxCrashesPerMinute;

  final List<_Worker> _workers = <_Worker>[];
  final List<DateTime> _crashes = <DateTime>[];
  final Completer<void> _done = Completer<void>();
  final List<StreamSubscription<ProcessSignal>> _signals = [];
  late final ReceivePort _inbox;
  late final SendPort _coordinatorPort;
  bool _stopping = false;
  int _exitCode = 0;

  /// Completes when every worker has stopped.
  Future<void> get done => _done.future;

  /// Exit code to use after [done] (1 on crash loop).
  int get exitCode => _exitCode;

  /// Ports reported by ready workers (all equal with `shared: true`).
  List<int> get ports => [
    for (final w in _workers)
      if (w.port != null) w.port!,
  ];

  /// Spawns the workers and waits until all are ready.
  Future<void> start() async {
    _coordinatorPort = coordinator.listen();
    _inbox = ReceivePort('daravel-supervisor');
    _inbox.listen(_onMessage);
    if (options.handleSignals) {
      _installSignalHandlers();
    }
    final readiness = <Future<void>>[];
    for (var i = 0; i < options.isolates; i++) {
      final worker = _Worker(i);
      _workers.add(worker);
      readiness.add(_spawn(worker));
    }
    await Future.wait(readiness);
    logger.info(
      'Daravel supervisor: ${options.isolates} workers listening on '
      'http://${options.host}:${ports.isEmpty ? options.port : ports.first}',
    );
  }

  /// Boots, serves until stopped and returns the exit code.
  Future<int> run() async {
    await start();
    await done;
    return exitCode;
  }

  final Map<int, Completer<void>> _ready = <int, Completer<void>>{};

  Future<void> _spawn(_Worker worker) async {
    final ready = Completer<void>();
    _ready[worker.index] = ready;
    worker.drained = false;
    final exitPort = ReceivePort();
    final errorPort = ReceivePort();
    worker.exitPort = exitPort;
    worker.errorPort = errorPort;
    final isolate = await Isolate.spawn<_WorkerSpawn>(
      _workerMain,
      _WorkerSpawn(
        index: worker.index,
        factory: factory,
        options: options,
        coordinator: _coordinatorPort,
        supervisor: _inbox.sendPort,
      ),
      debugName: 'daravel-worker-${worker.index}',
      onExit: exitPort.sendPort,
      onError: errorPort.sendPort,
      errorsAreFatal: true,
    );
    worker.isolate = isolate;
    errorPort.listen((Object? message) {
      if (message is List<Object?> && message.length == 2) {
        logger.error(
          'Worker ${worker.index} error: ${message[0]}',
          error: message[0],
          stackTrace: message[1] == null
              ? null
              : StackTrace.fromString('${message[1]}'),
        );
      }
    });
    exitPort.listen((_) => _onWorkerExit(worker));
    return ready.future.timeout(
      options.readyTimeout,
      onTimeout: () {
        throw StateError(
          'Worker ${worker.index} did not become ready within '
          '${options.readyTimeout.inSeconds}s.',
        );
      },
    );
  }

  void _onMessage(Object? message) {
    switch (message) {
      case WorkerReady():
        final worker = _workers[message.index];
        worker.control = message.control;
        worker.port = message.port;
        _ready.remove(message.index)?.complete();
        logger.debug('Worker ${message.index} ready on port ${message.port}');
      case WorkerFailed():
        _ready
            .remove(message.index)
            ?.completeError(
              StateError('Worker ${message.index} failed: ${message.error}'),
            );
      case WorkerDrained():
        _workers[message.index].drained = true;
    }
  }

  void _onWorkerExit(_Worker worker) {
    worker.exitPort?.close();
    worker.errorPort?.close();
    worker.isolate = null;
    worker.control = null;
    worker.port = null;
    if (_stopping) {
      _checkAllStopped();
      return;
    }
    if (_ready.containsKey(worker.index)) {
      // Died before ready: the readiness future reports it.
      return;
    }
    final now = DateTime.now();
    _crashes
      ..add(now)
      ..removeWhere((t) => now.difference(t) > const Duration(minutes: 1));
    if (_crashes.length >= maxCrashesPerMinute) {
      logger.error(
        'Crash loop: ${_crashes.length} worker exits within a minute; '
        'shutting down with exit code 1.',
      );
      _exitCode = 1;
      unawaited(stop());
      return;
    }
    final backoff = Duration(seconds: 1 << (_crashes.length - 1).clamp(0, 5));
    logger.warning(
      'Worker ${worker.index} exited unexpectedly; respawning in '
      '${backoff.inSeconds}s.',
    );
    unawaited(
      Future<void>.delayed(backoff, () async {
        if (_stopping) {
          return;
        }
        try {
          await _spawn(worker);
        } catch (error, stackTrace) {
          logger.error(
            'Respawn of worker ${worker.index} failed',
            error: error,
            stackTrace: stackTrace,
          );
          _onWorkerExit(worker);
        }
      }),
    );
  }

  /// Drains every worker (graceful) and completes [done].
  Future<void> stop() async {
    if (_stopping) {
      return done;
    }
    _stopping = true;
    for (final subscription in _signals) {
      await subscription.cancel();
    }
    _signals.clear();
    for (final worker in _workers) {
      worker.control?.send('drain');
    }
    final deadline = options.shutdownTimeout + const Duration(seconds: 2);
    await done.timeout(
      deadline,
      onTimeout: () {
        for (final worker in _workers) {
          if (worker.isolate != null) {
            logger.warning('Killing worker ${worker.index} after timeout.');
            worker.isolate?.kill(priority: Isolate.immediate);
            worker.isolate = null;
          }
        }
        _finish();
      },
    );
  }

  void _checkAllStopped() {
    if (_workers.every((w) => w.isolate == null)) {
      _finish();
    }
  }

  void _finish() {
    if (_done.isCompleted) {
      return;
    }
    _inbox.close();
    coordinator.close();
    _done.complete();
  }

  void _installSignalHandlers() {
    _signals.add(
      ProcessSignal.sigint.watch().listen((_) => _onSignal('SIGINT')),
    );
    if (!Platform.isWindows) {
      _signals.add(
        ProcessSignal.sigterm.watch().listen((_) => _onSignal('SIGTERM')),
      );
    }
  }

  void _onSignal(String name) {
    logger.info('Received $name, draining ${_workers.length} workers...');
    unawaited(stop());
  }

  static Future<void> _workerMain(_WorkerSpawn spawn) async {
    final control = ReceivePort('daravel-worker-${spawn.index}');
    final channel = RemoteCoordinatorChannel(spawn.coordinator);
    final Application app;
    try {
      app = spawn.factory();
      app.coordinator = channel;
      await app.boot();
    } catch (error) {
      spawn.supervisor.send(WorkerFailed(spawn.index, '$error'));
      control.close();
      return;
    }
    final engineOptions = ServeOptions(
      host: spawn.options.host,
      port: spawn.options.port,
      isolates: 1,
      shared: true,
      idleTimeout: spawn.options.idleTimeout,
      shutdownTimeout: spawn.options.shutdownTimeout,
      requestTimeout: spawn.options.requestTimeout,
      handleSignals: false,
      readyTimeout: spawn.options.readyTimeout,
      maxInFlight: spawn.options.maxInFlight,
      maxQueueDelay: spawn.options.maxQueueDelay,
    );
    control.listen((Object? message) {
      if (message == 'drain') {
        unawaited(app.shutdown());
      }
    });
    try {
      await app.serve(
        options: engineOptions,
        onStarted: (engine) => spawn.supervisor.send(
          WorkerReady(
            spawn.index,
            engine.port ?? spawn.options.port,
            control.sendPort,
          ),
        ),
      );
    } catch (error) {
      spawn.supervisor.send(WorkerFailed(spawn.index, '$error'));
    } finally {
      spawn.supervisor.send(WorkerDrained(spawn.index));
      channel.close();
      control.close();
    }
  }
}
