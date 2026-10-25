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
  'logging': {'foundation'},
  'storage': {'foundation'},
  'view': {'http'},
  'translation': {'foundation', 'http'},
  'features': {'foundation', 'database', 'auth', 'http'},
  'routing': {'foundation', 'http', 'validation'},
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
  'auth': {'foundation', 'http', 'database'},
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
  'observability': {'foundation', 'cache', 'database', 'http', 'server'},
  'support': {
    'foundation',
    'auth',
    'cache',
    'database',
    'events',
    'logging',
    'queue',
    'storage',
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
}
