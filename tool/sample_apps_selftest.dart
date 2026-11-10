import 'dart:io';

import 'sample_apps.dart';

/// Tests of tool/sample_apps.dart, run in CI:
/// `dart run tool/sample_apps_selftest.dart` (a plain program, as the
/// workspace root has no `package:test`).
void main() {
  var failures = 0;
  void check(String name, Object? actual, Object? expected) {
    if ('$actual' == '$expected') {
      stdout.writeln('ok   $name');
    } else {
      failures++;
      stderr.writeln('FAIL $name\n  expected: $expected\n  actual:   $actual');
    }
  }

  const workspace = Workspace(
    ['daravel', 'daravel_test', 'daravel_redis', 'daravel_excel'],
    {
      'starter': {'daravel', 'daravel_test'},
      'redis_demo': {'daravel', 'daravel_redis'},
    },
  );
  check('every app package is not sampled', workspace.sampled, [
    'daravel_redis',
    'daravel_excel',
  ]);
  check(
    'a package with an app needs no plan',
    sampleAppProblems(
      workspace,
      planned: {
        'daravel_excel': ['excel_demo'],
      },
    ),
    <String>[],
  );
  check(
    'a package with neither an app nor a plan',
    sampleAppProblems(workspace, planned: const {}).single,
    'daravel_excel is used by no application in apps/ and none is planned '
        'for it (tool/sample_apps.dart).',
  );
  check(
    'an app that exists leaves the plan',
    sampleAppProblems(
      workspace,
      planned: {
        'daravel_excel': ['x'],
        'daravel_redis': ['redis_demo'],
      },
    ).single,
    'apps/redis_demo exists: remove it from the planned apps of '
        'daravel_redis (tool/sample_apps.dart).',
  );
  check(
    'missing files',
    sampleAppProblems(
      const Workspace(
        ['daravel'],
        {'a': {}},
        missingFiles: {
          'a': ['README.id.md'],
        },
      ),
      planned: const {},
    ),
    ['apps/a has no README.id.md.'],
  );
  final readme = renderAppsReadme(
    workspace,
    planned: {
      'daravel_excel': ['excel_demo'],
    },
  );
  check(
    'the matrix row of a package',
    readme.split('\n').firstWhere((l) => l.startsWith('| `daravel_redis`')),
    '| `daravel_redis` |  | ✓ |  |',
  );
  check(
    'planned apps in the last column',
    readme.split('\n').firstWhere((l) => l.startsWith('| `daravel_excel`')),
    '| `daravel_excel` |  |  | `excel_demo` |',
  );
  check(
    'the application table',
    readme.contains(
      '| [`redis_demo`](redis_demo/README.md) | `daravel_redis` |',
    ),
    true,
  );
  check(
    'the repository passes',
    sampleAppProblems(Workspace.read(Directory.current.path)),
    <String>[],
  );
  if (failures > 0) {
    stderr.writeln('$failures failure(s).');
    exitCode = 1;
  }
}
