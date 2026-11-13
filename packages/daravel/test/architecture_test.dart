import 'dart:io';

import 'package:daravel_lints/daravel_lints.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Module dependency rules for `lib/src/<module>` (BLUEPRINT_V2 ADR-011).
///
/// The map records every edge that exists by design. A new cross-module
/// import fails this test until it is added here deliberately, which keeps
/// accidental coupling (and new cycles) visible in review.
const Map<String, Set<String>> allowedDependencies = {
  'foundation': {},
  // Plain schema documents: nothing else.
  'json_schema': {},
  'concurrency': {'foundation', 'http', 'logging'},
  'process': {'foundation'},
  'logging': {'foundation'},
  'storage': {'foundation'},
  // Ships SQLite's write-ahead log to a disk (Blueprint #30).
  'replication': {'foundation', 'storage'},
  'view': {'foundation', 'http'},
  'translation': {'foundation', 'http'},
  'features': {'foundation', 'database', 'auth', 'http'},
  'mail': {'foundation', 'logging', 'queue'},
  'notifications': {'foundation', 'mail', 'database', 'queue', 'broadcasting'},
  'broadcasting': {
    'json_schema',
    'foundation',
    'auth',
    'database',
    'http',
    'logging',
    'server',
  },
  'routing': {'foundation', 'http', 'validation', 'database', 'support'},
  'validation': {'foundation', 'http', 'database'},
  'database': {'foundation', 'http', 'logging'},
  'http': {
    'foundation',
    'logging',
    'routing',
    'server',
    'support',
    'validation',
    'database',
    'storage',
  },
  // Password hashing runs on a bounded compute pool (#163).
  'auth': {'foundation', 'http', 'database', 'concurrency'},
  'server': {'foundation', 'http', 'cache', 'logging', 'observability'},
  'cache': {'foundation', 'database', 'server'},
  'events': {'foundation', 'queue'},
  'queue': {
    'foundation',
    'cache',
    'database',
    'events',
    'http',
    'logging',
    'server',
  },
  'schedule': {'foundation', 'cache', 'events', 'logging', 'queue', 'server'},
  'observability': {
    'foundation',
    'cache',
    'database',
    'http',
    'logging',
    'server',
  },
  'support': {
    'foundation',
    'auth',
    'cache',
    'database',
    'events',
    'logging',
    'mail',
    'notifications',
    'queue',
    'server',
    'broadcasting',
    'storage',
    // Storage.download and Storage.response answer with a Response.
    'http',
  },
};

/// The composition root may import every module.
const String compositionRoot = 'foundation/application.dart';

final String _src = p.join(Directory.current.path, 'lib', 'src');

Iterable<File> _dartFiles(String dir) =>
    Directory(dir)
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));

String _module(String file) => p.split(p.relative(file, from: _src)).first;

void main() {
  test('module imports follow the allowed dependency graph', () {
    final violations = <String>[];
    final imports = RegExp(r'''^import '([^']+)';''', multiLine: true);
    for (final file in _dartFiles(_src)) {
      final relative = p.relative(file.path, from: _src).replaceAll(r'\', '/');
      if (relative == compositionRoot) {
        continue;
      }
      final from = _module(file.path);
      expect(
        allowedDependencies,
        contains(from),
        reason: 'Unknown module $from',
      );
      for (final match in imports.allMatches(file.readAsStringSync())) {
        final uri = match.group(1)!;
        if (uri.startsWith('package:') || uri.startsWith('dart:')) {
          continue;
        }
        final target = p.normalize(p.join(p.dirname(file.path), uri));
        final to = _module(target);
        if (to != from && !allowedDependencies[from]!.contains(to)) {
          violations.add('$relative imports $to ($uri)');
        }
      }
    }
    expect(violations, isEmpty, reason: violations.join('\n'));
  });

  test('the core never depends on testing or CLI packages', () {
    final forbidden = RegExp(
      r'''package:(daravel_test|dartisan_cli|test|daravel_lints)/''',
    );
    for (final file in _dartFiles(_src)) {
      expect(
        forbidden.hasMatch(file.readAsStringSync()),
        isFalse,
        reason: '${file.path} imports a dev-only package',
      );
    }
  });

  test('no reflection, no print, no mutable globals in lib/src', () {
    final issues = <LintIssue>[];
    for (final file in _dartFiles(_src)) {
      issues.addAll(
        lintSource(
          file.readAsStringSync(),
          p.relative(file.path, from: Directory.current.path),
          rules: const [NoDartMirrors(), NoPrintInApp()],
        ),
      );
      final source = file.readAsStringSync();
      final topLevelVar = RegExp(
        r'^(?:var|late var|[A-Z][\w<>?, ]*\s+[a-z_]\w*\s*=)',
        multiLine: true,
      );
      for (final match in topLevelVar.allMatches(source)) {
        final line = source.substring(0, match.start).split('\n').length;
        final text = source.split('\n')[line - 1];
        if (!text.startsWith('final') && !text.startsWith('const')) {
          fail('${file.path}:$line mutable top-level variable: $text');
        }
      }
    }
    expect(issues, isEmpty, reason: issues.join('\n'));
  });

  test('a Future or Completer kept in a field is one of the known ones', () {
    // A future kept in a field and awaited by another request, job or
    // connection must not be one that can fail: each runs in an error
    // zone of its own, and a failure does not cross into another (the
    // waiter hangs). Share a result with SharedResult; a field that is
    // safe (one zone, one owner) is added to _knownFutureFields with why.
    final field = RegExp(
      r'^  (?:static )?(?:final |late |late final )?'
      r'(?:Future<|Completer<|(?:Map|Expando|Set|List)<[^;=]*(?:Future|Completer)<)'
      r'[^;(]*>\??\s+(_?[a-zA-Z0-9_]+)\s*(?:;|=(?!>))',
      multiLine: true,
    );
    final found = <String>{};
    for (final file in _dartFiles(_src)) {
      final path = p.relative(file.path, from: _src).replaceAll(r'\', '/');
      for (final match in field.allMatches(file.readAsStringSync())) {
        found.add('$path:${match.group(1)}');
      }
    }
    final unknown = found.difference(_knownFutureFields.keys.toSet());
    final gone = _knownFutureFields.keys.toSet().difference(found);
    expect(unknown, isEmpty, reason: 'new Future or Completer fields');
    expect(gone, isEmpty, reason: 'listed but no longer there');
  });

  test('periodic timers and stream listeners are detached or known', () {
    // A Timer.periodic or a listen() started lazily from a request lives on
    // in that request's zone (its scope, log context, cancellation token;
    // Review #149). Each must sit inside runDetached (or Zone.root.run), or
    // be listed in _knownLongLived with how many there are and why.
    final site = RegExp(r'Timer\.periodic\(|\.listen\(');
    // A one-shot Timer whose callback calls the method around it again is
    // a periodic timer too (`void beat() { Timer(d, () { ...; beat(); }) }`).
    final oneShot = RegExp(r'(?<![.\w])Timer\(');
    final method = RegExp(
      r'^\s+(?:[\w<>?]+\s+)?(\w+)\([^)]*\)\s*(?:async\s*)?\{',
    );
    bool recurs(List<String> lines, int at) {
      for (var i = at; i >= 0 && i > at - 15; i--) {
        final name = method.firstMatch(lines[i])?.group(1);
        if (name != null) {
          final after = lines.sublist(at + 1, (at + 15).clamp(0, lines.length));
          return after.any((l) => l.contains('$name();'));
        }
      }
      return false;
    }

    final counts = <String, int>{};
    for (final file in _dartFiles(_src)) {
      final path = p.relative(file.path, from: _src).replaceAll(r'\', '/');
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i].trimLeft();
        if (line.startsWith('//')) {
          continue;
        }
        if (!site.hasMatch(line) &&
            !(oneShot.hasMatch(line) && recurs(lines, i))) {
          continue;
        }
        final before = lines.sublist(i < 4 ? 0 : i - 4, i + 1).join('\n');
        if (before.contains('runDetached') ||
            before.contains('Zone.root.run')) {
          continue;
        }
        counts[path] = (counts[path] ?? 0) + 1;
      }
    }
    final listed = {
      for (final MapEntry(:key, :value) in _knownLongLived.entries)
        key: value.$1,
    };
    expect(
      counts,
      listed,
      reason:
          'a new (or removed) periodic timer or listen(): detach it, or '
          'list it in _knownLongLived with why it is safe',
    );
  });
}

/// The periodic timers and `listen()` calls of lib/src outside runDetached,
/// per file: how many, and why each is safe where it is (see the test
/// above).
const Map<String, (int, String)> _knownLongLived = {
  'broadcasting/cluster.dart': (
    1,
    'the relay loop\'s notifications; the loop starts detached',
  ),
  'broadcasting/pusher_server.dart': (1, 'per WebSocket connection'),
  'database/database_manager.dart': (1, 'NotifyingDriver.listen, a call'),
  'database/postgres_driver.dart': (
    1,
    'LISTEN for its caller: the detached relay loop, or a worker loop',
  ),
  'foundation/application.dart': (1, 'coordinator.listen() at boot'),
  'foundation/embedded_workers.dart': (4, 'embedded workers, at boot'),
  'http/buffered_web_socket.dart': (1, 'per WebSocket connection'),
  'http/websocket_guard.dart': (
    3,
    'per WebSocket connection: the TCP socket read, and what the '
        'WebSocket reads and writes through the guard',
  ),
  'http/client.dart': (1, 'per response body'),
  'http/graceful_server_socket.dart': (1, 'the server socket, at start'),
  'http/multipart.dart': (2, 'per request body'),
  'http/realtime.dart': (
    2,
    'per SSE response: its events and its keep-alive (beat), which end '
        'with the response',
  ),
  'http/request.dart': (
    1,
    'per request body read; one refused while reading is left to the '
        'server, which answers and closes the connection',
  ),
  'http/server_engine.dart': (
    7,
    'the engine at start (lag sampler, sockets), and per connection (a '
        'WebSocket whose handler returned without listening included)',
  ),
  'mail/smtp.dart': (1, 'per SMTP connection, closed after the send'),
  'observability/metrics.dart': (1, 'the metrics publisher, at boot'),
  'queue/drivers.dart': (1, 'LISTEN of the worker loop that waits'),
  'queue/queue_manager.dart': (
    1,
    'touches one reserved job, in its zone, cancelled when it ends',
  ),
  'replication/replicator.dart': (1, 'the replication loop of its command'),
  'server/broadcast.dart': (1, 'per WebSocket connection (serve)'),
  'server/coordinator.dart': (
    2,
    'the coordinator and its lag probe (_probeLag), created at boot; the '
        "channels' timeout sweep runs detached",
  ),
  'server/process_supervisor.dart': (5, 'the process supervisor'),
  'server/supervisor.dart': (7, 'the isolate supervisor'),
  'support/facades.dart': (1, 'DB.listen, a call'),
  'validation/dns.dart': (
    1,
    'per MX lookup: its UDP socket, cancelled and closed when the lookup '
        'ends (answer, timeout or error)',
  ),
};

/// The Future and Completer fields of lib/src, each with why it is safe to
/// keep (see the test above).
const Map<String, String> _knownFutureFields = {
  'broadcasting/cluster.dart:_loop':
      'the relay loop, awaited only by close() at shutdown',
  'broadcasting/cluster.dart:_wake': 'wakes the relay loop; one owner',
  'cache/stores.dart:_lastRun':
      'background prune: never fails (catchError), awaited by tests only',
  'cache/stores.dart:_pruning': 'background prune: never fails (catchError)',
  'cache/stores.dart:_queued': 'completed with no error',
  'cache/stores.dart:next': 'completed with no error',
  'concurrency/compute_pool.dart:completer': 'one worker spawn, one owner',
  'concurrency/compute_pool.dart:_stopped': 'completed with no error',
  'database/database_manager.dart:_children': 'a chain that never fails',
  'database/orm/model.dart:future': 'per object, one owner',
  'database/sqlite_driver.dart:_transactionQueue': 'a chain that never fails',
  'database/sqlite_driver.dart:_activeDone': 'completed with no error',
  'foundation/application.dart:_booting': 'boot, in one zone',
  'foundation/drain.dart:_completer': 'completed with no error',
  'foundation/embedded_workers.dart:inbox': 'per worker, one owner',
  'foundation/embedded_workers.dart:done': 'per worker, one owner',
  'foundation/embedded_workers.dart:_stopping': 'per worker, one owner',
  'foundation/shared_result.dart:_settled': 'never fails, by design',
  'http/buffered_web_socket.dart:_binding': 'per connection, one zone',
  'http/buffered_web_socket.dart:_closed': 'per connection, one zone',
  'http/buffered_web_socket.dart:_gaveUp': 'completed with no error',
  'http/buffered_web_socket.dart:_drained': 'completed with no error',
  'http/websocket_guard.dart:_written':
      'per connection, one zone; its errors are absorbed',
  'http/websocket_guard.dart:_closed':
      'per connection, completed with no error',
  'http/kernel.dart:result': 'per request, one zone',
  'http/multipart.dart:_changed': 'per request body, one zone',
  'http/server_engine.dart:_done': 'completed with no error',
  'http/server_engine.dart:_arrival': 'completed with no error',
  'logging/logger.dart:_idle': 'completed with no error',
  'mail/smtp.dart:_waiting': 'per connection, one owner',
  'queue/drivers.dart:_waiting': 'completed with no error',
  'queue/drivers.dart:_subscribing':
      'LISTEN single flight: never fails, _subscribe catches the LISTEN',
  'queue/queue_manager.dart:_future': 'per PendingDispatch, one owner',
  'queue/queue_manager.dart:_idle': 'completed with no error',
  'schedule/schedule.dart:_ticks': 'the scheduler, one owner',
  'schedule/schedule.dart:_running': 'the scheduler, one owner',
  'schedule/schedule.dart:_wake': 'completed with no error',
  'server/broadcast.dart:_leaving':
      '_unregister catches every error: never fails',
  'server/coordinator.dart:completer': 'per call, completed by its reply',
  'server/process_supervisor.dart:_done': 'completed with no error',
  'server/supervisor.dart:_done': 'completed with no error',
  'server/supervisor.dart:_ready': 'per worker spawn, one owner',
  'server/supervisor.dart:exited': 'rolling restart: completed with no error',
  'server/supervisor.dart:replaced':
      'rolling restart: completed with a bool, never an error',
  'server/supervisor.dart:_rolling':
      'main isolate only; a round never fails (_roll catches all)',
  'server/supervisor.dart:_pendingRoll':
      'completed with a round, which never fails',
};
