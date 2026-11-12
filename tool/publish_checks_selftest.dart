import 'dart:io';

import 'publish_checks.dart';

/// Tests of the workflow checks in tool/publish_checks.dart, run in CI:
/// `dart run tool/publish_checks_selftest.dart`. The workspace root has no
/// `package:test`, so this is a plain program that exits 1 on a failure.
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

  const sha = '11d5960a326750d5838078e36cf38b85af677262';
  check(
    'a SHA, a commented SHA and a local action are pinned',
    unpinnedActions(
      '    steps:\n'
      '      - uses: actions/checkout@$sha\n'
      '      - uses: dart-lang/setup-dart@$sha # v1\n'
      '      - uses: ./.github/actions/local\n'
      '    uses: dart-lang/setup-dart/.github/workflows/publish.yml@$sha\n',
    ),
    <String>[],
  );
  check(
    'a tag, a branch and a short SHA are not',
    unpinnedActions(
      '      - uses: actions/checkout@v4\n'
      '    uses: dart-lang/setup-dart/.github/workflows/publish.yml@v1\n'
      '      - uses: actions/setup-node@main\n'
      '      - uses: actions/cache@11d5960\n',
    ),
    [
      'actions/checkout@v4',
      'dart-lang/setup-dart/.github/workflows/publish.yml@v1',
      'actions/setup-node@main',
      'actions/cache@11d5960',
    ],
  );

  String step(String name) =>
      '      - name: $name\n'
      "        if: needs.verify.outputs.$name != 'published'\n"
      '        working-directory: packages/$name\n'
      '        run: dart pub publish --force\n';
  check(
    'the publish order is the order of the steps',
    publishOrder('    steps:\n${step('daravel')}${step('daravel_test')}'),
    ['packages/daravel', 'packages/daravel_test'],
  );
  check(
    'one job with steps uses nothing forbidden',
    forbiddenInPublish(
      '    steps:\n      - uses: actions/checkout@$sha\n${step('daravel')}',
    ),
    <String>[],
  );
  // What 1.27.1 published with: one reusable-workflow call per package,
  // and the artifacts they pass.
  check(
    'the reusable workflow and artifact actions are refused',
    forbiddenInPublish(
      '    uses: dart-lang/setup-dart/.github/workflows/publish.yml@$sha\n'
      '      - uses: actions/upload-artifact@$sha\n'
      '      - uses: actions/download-artifact@$sha\n',
    ),
    [
      'dart-lang/setup-dart/.github/workflows/publish.yml',
      'actions/upload-artifact',
      'actions/download-artifact',
    ],
  );

  if (failures > 0) {
    stderr.writeln('$failures check(s) failed.');
    exitCode = 1;
  }
}
