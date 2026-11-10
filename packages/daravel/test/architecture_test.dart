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
}

/// The Future and Completer fields of lib/src, each with why it is safe to
/// keep (see the test above). Those marked "PR B" are known to share a
/// future that can fail across zones, and are being moved to SharedResult.
const Map<String, String> _knownFutureFields = {
  'auth/hashing.dart:_dummy': 'PR B: the timing equalizer, shared by logins',
  'broadcasting/cluster.dart:_loop': 'the relay loop, owned by one server',
  'broadcasting/cluster.dart:_wake': 'wakes the relay loop; one owner',
  'broadcasting/pusher_server.dart:_relaying': 'the relay task, one owner',
  'cache/cache.dart:_remembering': 'PR B: remember single flight',
  'cache/stores.dart:_lastRun': 'prune; to be read in PR C',
  'cache/stores.dart:_pruning': 'prune; to be read in PR C',
  'cache/stores.dart:_queued': 'completed with no error',
  'cache/stores.dart:next': 'completed with no error',
  'concurrency/compute_pool.dart:completer': 'one worker spawn, one owner',
  'concurrency/compute_pool.dart:_stopped': 'completed with no error',
  'database/database_manager.dart:_connecting':
      'PR B: connection single flight',
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
  'http/kernel.dart:result': 'per request, one zone',
  'http/multipart.dart:_changed': 'per request body, one zone',
  'http/server_engine.dart:_done': 'completed with no error',
  'http/server_engine.dart:_arrival': 'completed with no error',
  'logging/logger.dart:_idle': 'completed with no error',
  'mail/smtp.dart:_waiting': 'per connection, one owner',
  'queue/drivers.dart:_waiting': 'completed with no error',
  'queue/drivers.dart:_subscribing': 'to be read in PR C',
  'queue/queue_manager.dart:_future': 'per PendingDispatch, one owner',
  'queue/queue_manager.dart:_idle': 'completed with no error',
  'schedule/schedule.dart:_ticks': 'the scheduler, one owner',
  'schedule/schedule.dart:_running': 'the scheduler, one owner',
  'schedule/schedule.dart:_wake': 'completed with no error',
  'server/broadcast.dart:_registering': 'PR B: channel registration',
  'server/broadcast.dart:_leaving': 'PR B: channel registration',
  'server/coordinator.dart:completer': 'per call, completed by its reply',
  'server/process_supervisor.dart:_done': 'completed with no error',
  'server/supervisor.dart:_done': 'completed with no error',
  'server/supervisor.dart:_ready': 'per worker spawn, one owner',
};
