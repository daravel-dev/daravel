import 'dart:io';

import 'sample_apps.dart';

/// Checks the sample applications in `apps/` (Blueprint #136):
///
/// ```bash
/// dart run tool/sample_apps_check.dart          # CI: the rules and apps/README.md
/// dart run tool/sample_apps_check.dart --write  # regenerate apps/README.md
/// ```
///
/// Every package outside `daravel`, `daravel_test`, `daravel_lints` and
/// `dartisan_cli` is used by an application or has one planned
/// ([planned]); every application has `bin/dartisan.dart`, `test/`, both
/// READMEs and `.env.example`; and `apps/README.md` holds the generated
/// package × application matrix.
void main(List<String> args) {
  final root = Directory.current.path;
  final workspace = Workspace.read(root);
  final readme = File('$root/apps/README.md');
  final expected = renderAppsReadme(workspace);
  if (args.contains('--write')) {
    readme.writeAsStringSync(expected);
    stdout.writeln('Wrote apps/README.md.');
  }
  final problems = [
    ...sampleAppProblems(workspace),
    if (!readme.existsSync() ||
        readme.readAsStringSync().replaceAll('\r\n', '\n') != expected)
      'apps/README.md is out of date: run '
          'dart run tool/sample_apps_check.dart --write',
  ];
  if (problems.isEmpty) {
    stdout.writeln(
      'Every package has a sample application or a planned one, and '
      'apps/README.md is up to date.',
    );
    return;
  }
  for (final problem in problems) {
    stderr.writeln('- $problem');
  }
  exitCode = 1;
}
