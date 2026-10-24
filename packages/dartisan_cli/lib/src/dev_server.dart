import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart' as vm;
import 'package:vm_service/vm_service_io.dart' as vm_io;
import 'package:watcher/watcher.dart';

/// How a set of file changes is applied (ADR-010).
enum ReloadAction { hotReload, restart }

/// Decides between hot reload and restart for changed [paths] (relative to
/// the project root). Boot-time inputs (env, bootstrap registries, routes,
/// migrations, pubspec) require a restart because they are read once.
ReloadAction actionFor(Iterable<String> paths) {
  for (final raw in paths) {
    final path = raw.replaceAll(r'\', '/');
    final name = p.posix.basename(path);
    if (name.startsWith('.env') ||
        name == 'pubspec.yaml' ||
        name == 'pubspec.lock' ||
        path.startsWith('bootstrap/') ||
        path.startsWith('routes/') ||
        path.startsWith('database/') ||
        path.startsWith('config/')) {
      return ReloadAction.restart;
    }
  }
  return ReloadAction.hotReload;
}

/// `dartisan serve --watch`: runs `bin/server.dart` in a child VM with the
/// VM service enabled, watches the project and hot-reloads (or restarts).
final class DevServer {
  DevServer({
    required this.root,
    required this.dart,
    this.environment = const <String, String>{},
    this.debounce = const Duration(milliseconds: 300),
    StringSink? out,
  }) : _out = out ?? stdout;

  final String root;
  final String dart;
  final Map<String, String> environment;
  final Duration debounce;
  final StringSink _out;

  static const List<String> watched = <String>[
    'lib',
    'bin',
    'bootstrap',
    'routes',
    'config',
    'database',
  ];

  Process? _process;
  vm.VmService? _service;
  final List<StreamSubscription<Object?>> _subscriptions = [];
  final Set<String> _pending = <String>{};
  Timer? _timer;
  bool _busy = false;
  bool _stopped = false;
  final Completer<void> _done = Completer<void>();

  /// Completes when [stop] is called.
  Future<void> get done => _done.future;

  /// Starts the child process and the watchers.
  Future<void> start() async {
    await _spawn();
    for (final dir in watched) {
      final path = p.join(root, dir);
      if (Directory(path).existsSync()) {
        _subscriptions.add(DirectoryWatcher(path).events.listen(_onEvent));
      }
    }
    for (final file in ['.env', 'pubspec.yaml']) {
      final path = p.join(root, file);
      if (File(path).existsSync()) {
        _subscriptions.add(FileWatcher(path).events.listen(_onEvent));
      }
    }
    _out.writeln(
      'Watching ${watched.join(', ')} and .env — hot reload on save, '
      'restart for bootstrap/routes/database/.env changes. Ctrl+C to stop.',
    );
  }

  void _onEvent(WatchEvent event) {
    final relative = p.relative(event.path, from: root);
    if (!relative.endsWith('.dart') &&
        !p.basename(relative).startsWith('.env') &&
        !relative.endsWith('pubspec.yaml')) {
      return;
    }
    _pending.add(relative);
    _timer?.cancel();
    _timer = Timer(debounce, _apply);
  }

  Future<void> _apply() async {
    if (_busy || _pending.isEmpty || _stopped) {
      return;
    }
    _busy = true;
    final changed = Set<String>.of(_pending);
    _pending.clear();
    final stopwatch = Stopwatch()..start();
    try {
      if (actionFor(changed) == ReloadAction.restart) {
        _out.writeln('Restarting (${changed.join(', ')})...');
        await restart();
        _out.writeln('Restarted in ${stopwatch.elapsedMilliseconds} ms.');
        return;
      }
      final reloaded = await hotReload();
      if (reloaded) {
        _out.writeln(
          'Reloaded ${changed.length} file(s) in ${stopwatch.elapsedMilliseconds} ms.',
        );
      }
    } catch (error) {
      _out.writeln('Reload failed ($error); restarting.');
      await restart();
    } finally {
      _busy = false;
      if (_pending.isNotEmpty) {
        unawaited(_apply());
      }
    }
  }

  /// Reloads sources in every isolate. Compile errors are printed and the
  /// running code is kept; returns whether the reload succeeded.
  Future<bool> hotReload() async {
    final service = _service;
    if (service == null) {
      await restart();
      return true;
    }
    final vmInfo = await service.getVM();
    var ok = true;
    for (final isolate in vmInfo.isolates ?? const <vm.IsolateRef>[]) {
      final report = await service.reloadSources(isolate.id!);
      if (report.success != true) {
        ok = false;
        final notices = report.json?['notices'];
        final message = notices is List && notices.isNotEmpty
            ? (notices.first as Map<String, Object?>)['message']
            : 'unknown error';
        _out.writeln('Hot reload rejected: $message');
        break;
      }
    }
    return ok;
  }

  /// Kills and respawns the child process.
  Future<void> restart() async {
    await _kill();
    await _spawn();
  }

  Future<void> _spawn() async {
    final process = await Process.start(
      dart,
      const <String>[
        'run',
        '--enable-vm-service=0',
        '--disable-service-auth-codes',
        'bin/server.dart',
      ],
      workingDirectory: root,
      environment: <String, String>{...environment, 'APP_ISOLATES': '1'},
    );
    _process = process;
    final uri = Completer<Uri>();
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          final match = RegExp(
            r'(http://127\.0\.0\.1:\d+/[^\s]*)',
          ).firstMatch(line);
          if (!uri.isCompleted &&
              line.contains('listening on') &&
              match != null) {
            uri.complete(Uri.parse(match.group(1)!));
            return;
          }
          _out.writeln(line);
        });
    process.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_out.writeln);
    unawaited(
      process.exitCode.then((code) {
        if (!_stopped && identical(_process, process)) {
          _out.writeln('Server exited with code $code; waiting for changes.');
          _service = null;
        }
        if (!uri.isCompleted) {
          uri.completeError(
            StateError('Server exited before the VM service started.'),
          );
        }
      }),
    );
    try {
      final http = await uri.future.timeout(const Duration(seconds: 60));
      final ws = http.replace(
        scheme: 'ws',
        path: '${http.path.endsWith('/') ? http.path : '${http.path}/'}ws',
      );
      _service = await vm_io.vmServiceConnectUri(ws.toString());
    } catch (error) {
      _out.writeln(
        'Hot reload unavailable ($error); file changes will restart the server.',
      );
      _service = null;
    }
  }

  Future<void> _kill() async {
    final process = _process;
    _process = null;
    await _service?.dispose();
    _service = null;
    if (process != null) {
      process.kill(
        Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigint,
      );
      await process.exitCode.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          process.kill(ProcessSignal.sigkill);
          return -1;
        },
      );
    }
  }

  /// Stops watching and terminates the child.
  Future<void> stop() async {
    if (_stopped) {
      return;
    }
    _stopped = true;
    _timer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    await _kill();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}
