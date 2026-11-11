// Measures what the plugin costs in the editor: starts the Dart analysis
// server over LSP (as VS Code and IntelliJ do), opens a file, edits it
// [runs] times and records how long each edit takes until the server
// publishes the diagnostics of that file: an analyzer one (a new unused
// variable) and, with the plugin enabled, a plugin one (`print` in
// lib/app, `no_print_in_app`). Ends with the server's working set.
//
//   dart run tool/editor_latency.dart <workspace root> <file> [runs] [--plugin]
//
// With --plugin it first waits (up to 3 minutes) for the plugin's first
// diagnostic and reports that as the plugin's start-up, apart from the
// timed edits: the server starts the plugin isolate after its own
// analysis, so the first edits would otherwise measure the start-up.
//
// Enable or disable the plugin in the workspace root's
// analysis_options.yaml (`plugins: daravel_lints_plugin: path: ...`)
// between two runs to compare.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    stderr.writeln('usage: editor_latency.dart <root> <file> [runs]');
    exitCode = 64;
    return;
  }
  final root = Directory(args[0]).absolute.path;
  final file = File(args[1]).absolute;
  final plugin = args.contains('--plugin');
  final positional = args.where((a) => !a.startsWith('--')).toList();
  final runs = positional.length > 2 ? int.parse(positional[2]) : 10;
  final server = await _Lsp.start(root);
  try {
    final uri = file.uri.toString();
    final original = file.readAsStringSync();
    await server.request('initialize', {
      'processId': pid,
      'rootUri': Directory(root).uri.toString(),
      'workspaceFolders': [
        {'uri': Directory(root).uri.toString(), 'name': 'root'},
      ],
      'capabilities': {
        'textDocument': {
          'publishDiagnostics': <String, Object?>{},
          'synchronization': {'didSave': false},
        },
      },
    });
    server.notify('initialized', <String, Object?>{});
    stdout.writeln('waiting for the initial analysis...');
    await server.quiet(const Duration(seconds: 5), const Duration(minutes: 5));
    server.notify('textDocument/didOpen', {
      'textDocument': {
        'uri': uri,
        'languageId': 'dart',
        'version': 1,
        'text': original,
      },
    });
    await server.quiet(const Duration(seconds: 3), const Duration(minutes: 2));
    var version = 1;
    if (plugin) {
      final clock = Stopwatch()..start();
      final ready = server.diagnostics.firstWhere(
        (e) =>
            e.uri == uri &&
            e.messages.any((m) => m.contains('instead of print')),
      );
      server.notify('textDocument/didChange', {
        'textDocument': {'uri': uri, 'version': ++version},
        'contentChanges': [
          {'text': "$original\nvoid latencyWarmUp() {\n  print('x');\n}\n"},
        ],
      });
      final started = await ready
          .then((_) => true)
          .timeout(const Duration(minutes: 3), onTimeout: () => false);
      stdout.writeln(
        started
            ? 'plugin start-up: ${clock.elapsedMilliseconds} ms after the '
                  'initial analysis'
            : 'plugin start-up: no plugin diagnostic within 3 minutes',
      );
      await server.quiet(
        const Duration(seconds: 1),
        const Duration(seconds: 30),
      );
    }
    final core = <int>[];
    final pluginTimes = <int>[];
    for (var i = 1; i <= runs; i++) {
      final text =
          '$original\nvoid latencyProbe$i() {\n  var unused$i = 0;\n'
          "  print('x');\n}\n";
      final clock = Stopwatch()..start();
      int? coreMs;
      int? pluginMs;
      final done = Completer<void>();
      final sub = server.diagnostics.listen((event) {
        if (event.uri != uri) {
          return;
        }
        final messages = event.messages;
        if (coreMs == null && messages.any((m) => m.contains('unused$i'))) {
          coreMs = clock.elapsedMilliseconds;
        }
        if (pluginMs == null &&
            messages.any((m) => m.contains('instead of print'))) {
          pluginMs = clock.elapsedMilliseconds;
        }
        if (coreMs != null && pluginMs != null && !done.isCompleted) {
          done.complete();
        }
      });
      server.notify('textDocument/didChange', {
        'textDocument': {'uri': uri, 'version': ++version},
        'contentChanges': [
          {'text': text},
        ],
      });
      await done.future.timeout(const Duration(seconds: 30), onTimeout: () {});
      await sub.cancel();
      if (coreMs != null) {
        core.add(coreMs!);
      }
      if (pluginMs != null) {
        pluginTimes.add(pluginMs!);
      }
      stdout.writeln(
        'edit $i: analyzer ${coreMs ?? '-'} ms, plugin ${pluginMs ?? '-'} ms',
      );
      // Let the server settle before the next edit.
      await server.quiet(
        const Duration(seconds: 1),
        const Duration(seconds: 30),
      );
    }
    stdout
      ..writeln(
        'analyzer diagnostic: median ${_median(core)} ms (n=${core.length})',
      )
      ..writeln(
        'plugin diagnostic:   median ${_median(pluginTimes)} ms '
        '(n=${pluginTimes.length})',
      )
      ..writeln('server working set:  ${await server.workingSetMb()} MB');
  } finally {
    await server.stop();
  }
}

String _median(List<int> values) {
  if (values.isEmpty) {
    return '-';
  }
  final sorted = [...values]..sort();
  return '${sorted[sorted.length ~/ 2]}';
}

typedef _Published = ({String uri, List<String> messages});

final class _Lsp {
  _Lsp._(this._process) {
    _process.stdout.listen(_read);
    _process.stderr.drain<void>();
  }

  static Future<_Lsp> start(String root) async => _Lsp._(
    await Process.start(Platform.resolvedExecutable, [
      'language-server',
      '--protocol=lsp',
      '--client-id=daravel-editor-latency',
      '--client-version=1',
    ], workingDirectory: root),
  );

  final Process _process;
  final _buffer = <int>[];
  int _nextId = 1;
  final _pending = <int, Completer<Object?>>{};
  final _diagnostics = StreamController<_Published>.broadcast();
  DateTime _lastMessage = DateTime.now();

  Stream<_Published> get diagnostics => _diagnostics.stream;

  Future<Object?> request(String method, Object? params) {
    final id = _nextId++;
    final completer = _pending[id] = Completer<Object?>();
    _send({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params});
    return completer.future;
  }

  void notify(String method, Object? params) =>
      _send({'jsonrpc': '2.0', 'method': method, 'params': params});

  /// Waits until the server has sent nothing for [silence] (at most [max]).
  Future<void> quiet(Duration silence, Duration max) async {
    final deadline = DateTime.now().add(max);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (DateTime.now().difference(_lastMessage) >= silence) {
        return;
      }
    }
  }

  Future<String> workingSetMb() async {
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-Command',
      '(Get-Process -Id ${_process.pid}).WorkingSet64',
    ]);
    final bytes = int.tryParse('${result.stdout}'.trim());
    return bytes == null ? '?' : (bytes / (1024 * 1024)).toStringAsFixed(0);
  }

  Future<void> stop() async {
    try {
      await request('shutdown', null).timeout(const Duration(seconds: 10));
      notify('exit', null);
    } on Object {
      // Kill below.
    }
    await Future<void>.delayed(const Duration(seconds: 1));
    _process.kill();
  }

  void _send(Map<String, Object?> message) {
    final body = utf8.encode(jsonEncode(message));
    _process.stdin
      ..add(ascii.encode('Content-Length: ${body.length}\r\n\r\n'))
      ..add(body);
  }

  void _read(List<int> chunk) {
    _buffer.addAll(chunk);
    while (true) {
      final text = latin1.decode(_buffer, allowInvalid: true);
      final headerEnd = text.indexOf('\r\n\r\n');
      if (headerEnd == -1) {
        return;
      }
      final length = int.parse(
        RegExp(r'Content-Length: (\d+)').firstMatch(text)!.group(1)!,
      );
      final start = headerEnd + 4;
      if (_buffer.length < start + length) {
        return;
      }
      final body = utf8.decode(_buffer.sublist(start, start + length));
      _buffer.removeRange(0, start + length);
      _lastMessage = DateTime.now();
      _handle(jsonDecode(body) as Map<String, Object?>);
    }
  }

  void _handle(Map<String, Object?> message) {
    final id = message['id'];
    if (id is int &&
        _pending.containsKey(id) &&
        !message.containsKey('method')) {
      _pending.remove(id)!.complete(message['result']);
      return;
    }
    if (message['method'] == 'textDocument/publishDiagnostics') {
      final params = message['params']! as Map<String, Object?>;
      _diagnostics.add((
        uri: params['uri']! as String,
        messages: [
          for (final d
              in (params['diagnostics']! as List<Object?>)
                  .cast<Map<String, Object?>>())
            '${d['code']} ${d['message']}',
        ],
      ));
    } else if (id != null && message.containsKey('method')) {
      // A request from the server (workspace/configuration, ...): answer
      // with nothing.
      _send({'jsonrpc': '2.0', 'id': id, 'result': null});
    }
  }
}
