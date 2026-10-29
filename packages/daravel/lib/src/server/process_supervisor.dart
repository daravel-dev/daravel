import 'dart:async';
import 'dart:io';

import '../http/server_engine.dart';
import '../logging/logger.dart';

/// Runs the server as several operating-system processes on consecutive
/// ports, for a reverse proxy to balance (ADR-027): `APP_PROCESSES=N` or
/// `serve --processes=N`.
///
/// The isolates of one process share a heap, so an endpoint that allocates
/// a lot per request (a thousand wide rows decoded and encoded as JSON)
/// gains little from more isolates; separate processes scale. Dart has no
/// `SO_REUSEPORT`, so each process listens on its own port:
/// `APP_PORT`, `APP_PORT + 1`, ... Every child gets `APP_PROCESSES=1`,
/// `DARAVEL_PROCESS_INDEX` and `DARAVEL_PROCESS_COUNT` in its environment
/// and runs [arguments] on [executable] (the same binary, or `dart` with
/// the same script).
///
/// State in the `process` cache store, the coordinator's rate limits and
/// locks is per process: [Application.serveWith] refuses to start unless
/// those are on a shared store (`database`, Redis) or
/// `APP_PROCESSES_ALLOW_UNSHARED_STATE=true`.
///
/// A child that exits is restarted with a growing delay; more than
/// [maxCrashesPerMinute] crashes in a minute stop everything with exit
/// code 1. `SIGINT`/`SIGTERM` forward `SIGTERM` to every child (a kill on
/// Windows) and wait for [ServeOptions.shutdownTimeout].
final class ProcessSupervisor {
  ProcessSupervisor({
    required this.executable,
    required this.arguments,
    required this.options,
    required this.processes,
    required this.logger,
    Map<String, String> environment = const <String, String>{},
    this.maxCrashesPerMinute = 5,
    this.handleSignals = true,
  }) : environment = Map.unmodifiable(environment);

  final String executable;
  final List<String> arguments;
  final ServeOptions options;
  final int processes;
  final Logger logger;

  /// Variables added to each child's environment (on top of this
  /// process's), before the per-child port and index.
  final Map<String, String> environment;
  final int maxCrashesPerMinute;
  final bool handleSignals;

  final Map<int, Process> _children = <int, Process>{};
  final List<DateTime> _crashes = <DateTime>[];
  final List<StreamSubscription<ProcessSignal>> _signals = [];
  final Completer<void> _done = Completer<void>();
  bool _stopping = false;
  int _exitCode = 0;

  /// The port of child [index].
  int portOf(int index) => options.port + index;

  /// Every child's port, for the proxy configuration.
  List<int> get ports => [for (var i = 0; i < processes; i++) portOf(i)];

  /// Completes when every child has stopped.
  Future<void> get done => _done.future;

  int get exitCode => _exitCode;

  /// Starts the children and waits until each answers on its port.
  Future<void> start() async {
    if (processes < 2) {
      throw ArgumentError.value(processes, 'processes', 'needs at least 2');
    }
    if (handleSignals) {
      _installSignalHandlers();
    }
    for (var i = 0; i < processes; i++) {
      await _spawn(i);
    }
    await Future.wait([for (var i = 0; i < processes; i++) _waitReady(i)]);
    logger.info(
      'Daravel: $processes processes listening on ${options.host}:'
      '${ports.first}-${ports.last}. Proxy upstream:\n${upstreamBlock()}',
    );
  }

  /// Starts, waits for the children and returns the exit code.
  Future<int> run() async {
    await start();
    await done;
    return exitCode;
  }

  /// An nginx `upstream` block (Caddy: `reverse_proxy` with the same
  /// addresses) that balances over the children.
  String upstreamBlock() {
    final buffer = StringBuffer('upstream daravel {\n');
    for (final port in ports) {
      buffer.writeln('    server ${options.host}:$port;');
    }
    buffer
      ..writeln('    keepalive 64;')
      ..write('}');
    return buffer.toString();
  }

  Future<void> _spawn(int index) async {
    final process = await Process.start(
      executable,
      arguments,
      environment: <String, String>{
        ...environment,
        'APP_HOST': options.host,
        'APP_PORT': '${portOf(index)}',
        'APP_PROCESSES': '1',
        'DARAVEL_PROCESS_INDEX': '$index',
        'DARAVEL_PROCESS_COUNT': '$processes',
        // The child exits when its stdin closes, which the operating system
        // does when this process dies, even when it is killed outright
        // (no signal reaches it on Windows): no orphan keeps the port.
        'DARAVEL_PROCESS_WATCH_PARENT': 'stdin',
      },
    );
    // Logs go where this process's go; stdin stays open as the lifeline.
    process.stdout.listen(stdout.add, onError: (Object _) {});
    process.stderr.listen(stderr.add, onError: (Object _) {});
    _children[index] = process;
    logger.info('Process $index (pid ${process.pid}) on port ${portOf(index)}');
    unawaited(process.exitCode.then((code) => _onExit(index, process, code)));
  }

  Future<void> _waitReady(int index) async {
    final deadline = DateTime.now().add(options.readyTimeout);
    while (true) {
      if (_stopping) {
        throw StateError(
          'Process $index exited before it was ready'
          '${_exitCode == 0 ? '' : ' (crash loop)'}.',
        );
      }
      // A child missing here exited and is being respawned: keep waiting.
      try {
        final socket = await Socket.connect(
          options.host,
          portOf(index),
          timeout: const Duration(seconds: 1),
        );
        socket.destroy();
        return;
      } on SocketException {
        if (DateTime.now().isAfter(deadline)) {
          throw TimeoutException(
            'Process $index did not listen on port ${portOf(index)} within '
            '${options.readyTimeout.inSeconds}s.',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  }

  void _onExit(int index, Process process, int code) {
    if (_children[index] != process) {
      return;
    }
    _children.remove(index);
    if (_stopping) {
      if (_children.isEmpty && !_done.isCompleted) {
        _done.complete();
      }
      return;
    }
    final now = DateTime.now();
    _crashes
      ..removeWhere((t) => now.difference(t) > const Duration(minutes: 1))
      ..add(now);
    if (_crashes.length > maxCrashesPerMinute) {
      logger.error(
        'Process $index exited ($code); ${_crashes.length} exits in a '
        'minute, stopping.',
      );
      _exitCode = 1;
      unawaited(stop());
      return;
    }
    logger.error('Process $index exited ($code); restarting.');
    Timer(Duration(seconds: _crashes.length), () {
      if (!_stopping) {
        unawaited(_spawn(index));
      }
    });
  }

  /// Asks every child to stop and waits up to the shutdown timeout before
  /// killing the rest.
  Future<void> stop() async {
    if (_stopping) {
      return done;
    }
    _stopping = true;
    for (final subscription in _signals) {
      await subscription.cancel();
    }
    _signals.clear();
    if (_children.isEmpty) {
      if (!_done.isCompleted) {
        _done.complete();
      }
      return;
    }
    for (final child in _children.values) {
      child.kill(
        Platform.isWindows ? ProcessSignal.sigkill : ProcessSignal.sigterm,
      );
    }
    await done.timeout(
      options.shutdownTimeout + const Duration(seconds: 2),
      onTimeout: () {
        for (final child in _children.values) {
          logger.warning('Process ${child.pid} did not stop in time; killing.');
          child.kill(ProcessSignal.sigkill);
        }
        if (!_done.isCompleted) {
          _done.complete();
        }
      },
    );
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
    logger.info('Received $name, stopping ${_children.length} processes...');
    unawaited(stop());
  }
}

/// In a child of [ProcessSupervisor] (`DARAVEL_PROCESS_WATCH_PARENT=stdin`),
/// calls [onParentGone] once the parent's end of stdin closes: the parent
/// stopped, crashed or was killed. Does nothing in any other process.
void watchSupervisorParent(
  Map<String, String> environment,
  Future<void> Function() onParentGone,
) {
  if (environment['DARAVEL_PROCESS_WATCH_PARENT'] != 'stdin') {
    return;
  }
  stdin.listen(
    (_) {},
    onDone: () => unawaited(onParentGone()),
    onError: (Object _) => unawaited(onParentGone()),
    cancelOnError: true,
  );
}

/// The arguments that start this same program again: for an AOT binary
/// none beyond [extra]; under `dart`, the VM flags and the script.
List<String> selfArguments([List<String> extra = const <String>[]]) {
  final script = Platform.script.toFilePath();
  final isScript =
      script != Platform.resolvedExecutable &&
      !script.endsWith('.snapshot') &&
      script.endsWith('.dart');
  return <String>[
    if (isScript) ...Platform.executableArguments,
    if (isScript) script,
    ...extra,
  ];
}
