import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:watcher/watcher.dart';

/// `client:flutter --watch`: regenerates the client when routes, requests,
/// resources or `.env` change. The route table is compiled into the
/// running process, so each run is a fresh `dartisan client:flutter`
/// ([regenerate]); runs never overlap, and changes made during one start
/// another.
final class ClientWatcher {
  ClientWatcher({
    required this.root,
    required this.regenerate,
    this.exclude,
    this.debounce = const Duration(milliseconds: 300),
    StringSink? out,
  }) : _out = out ?? stdout;

  final String root;

  /// Regenerates the client; returns the exit code.
  final Future<int> Function() regenerate;

  /// Ignored directory (the generated package, when it is inside [root]).
  final String? exclude;
  final Duration debounce;
  final StringSink _out;

  static const List<String> watched = ['lib', 'routes', 'bootstrap', 'config'];

  final List<StreamSubscription<WatchEvent>> _subscriptions = [];
  final Set<String> _pending = <String>{};
  Timer? _timer;
  bool _busy = false;
  final Completer<void> _done = Completer<void>();

  /// Completes when [stop] is called.
  Future<void> get done => _done.future;

  /// Starts watching; resolves once the watchers are ready.
  Future<void> start() async {
    final watchers = <Watcher>[
      for (final dir in watched)
        if (Directory(p.join(root, dir)).existsSync())
          DirectoryWatcher(p.join(root, dir)),
      if (File(p.join(root, '.env')).existsSync())
        FileWatcher(p.join(root, '.env')),
    ];
    for (final watcher in watchers) {
      _subscriptions.add(watcher.events.listen(_onEvent));
    }
    await Future.wait(watchers.map((w) => w.ready));
    _out.writeln(
      'Watching ${watched.join(', ')} and .env; the client is regenerated '
      'on save. Ctrl+C to stop.',
    );
  }

  void _onEvent(WatchEvent event) {
    final path = p.normalize(event.path);
    final skip = exclude;
    if (skip != null && p.isWithin(p.normalize(skip), path)) {
      return;
    }
    final name = p.basename(path);
    if (!name.endsWith('.dart') && !name.startsWith('.env')) {
      return;
    }
    _pending.add(p.relative(path, from: root));
    _timer?.cancel();
    _timer = Timer(debounce, _run);
  }

  Future<void> _run() async {
    if (_busy || _pending.isEmpty || _done.isCompleted) {
      return;
    }
    _busy = true;
    final changed = Set<String>.of(_pending);
    _pending.clear();
    try {
      _out.writeln('Regenerating (${changed.join(', ')})...');
      final code = await regenerate();
      if (code != 0) {
        _out.writeln('Generation failed (exit $code); fix it and save again.');
      }
    } finally {
      _busy = false;
      if (_pending.isNotEmpty) {
        unawaited(_run());
      }
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    for (final subscription in _subscriptions) {
      await subscription.cancel();
    }
    _subscriptions.clear();
    if (!_done.isCompleted) {
      _done.complete();
    }
  }
}
