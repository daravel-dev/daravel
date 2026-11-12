import 'dart:io';

import 'package:daravel_lints/daravel_lints.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _root(String? root) => root ?? Directory.current.path;

void _expectNoIssues(List<LintIssue> issues, String what) {
  if (issues.isNotEmpty) {
    fail('$what:\n${issues.map((i) => '  $i').join('\n')}');
  }
}

/// The project passes the `daravel_lints` rules it enables, as
/// `dartisan lint` runs them: the default rules and the registry check,
/// with the `diagnostics:` of its `analysis_options.yaml` ([lintConfig]).
/// [enable] names opt-in rules to run as well:
/// `expectLintClean(null, ['prefer_sql_identifier'])`.
void expectLintClean([String? root, Iterable<String> enable = const []]) {
  final path = _root(root);
  final config = lintConfig(path).withOverrides(enable: enable);
  for (final warning in config.warnings) {
    printOnFailure(warning);
  }
  _expectNoIssues(
    lintProject(path, rules: config.rules, registries: config.registries),
    'Lint findings',
  );
}

/// No mutable static or top-level state in `lib/app` (state would leak
/// between requests served by the same isolate).
void expectNoMutableStatics([String? root]) => _expectNoIssues(
  lintProject(
    _root(root),
    rules: const [NoMutableStaticInApp()],
  ).where((i) => i.rule == 'no_mutable_static_in_app').toList(),
  'Mutable static state',
);

/// Every migration, seeder, job and console command is listed in its
/// `bootstrap/` registry.
void expectRegistryComplete([String? root]) =>
    _expectNoIssues(checkRegistries(_root(root)), 'Unregistered classes');

/// No Dart file under [directory] imports a URI matching any of
/// [forbidden] (e.g. controllers must not import `dart:io`).
void expectNoImports(
  String directory,
  List<Pattern> forbidden, {
  String? root,
}) {
  final dir = Directory(p.join(_root(root), directory));
  if (!dir.existsSync()) {
    return;
  }
  final violations = <String>[];
  final importPattern = RegExp(
    r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
    multiLine: true,
  );
  for (final file in dir.listSync(recursive: true).whereType<File>()) {
    if (!file.path.endsWith('.dart')) {
      continue;
    }
    for (final match in importPattern.allMatches(file.readAsStringSync())) {
      final uri = match.group(1)!;
      if (forbidden.any((pattern) => pattern.allMatches(uri).isNotEmpty)) {
        violations.add(
          '${p.relative(file.path, from: _root(root))} imports $uri',
        );
      }
    }
  }
  if (violations.isNotEmpty) {
    fail('Forbidden imports:\n  ${violations.join('\n  ')}');
  }
}
