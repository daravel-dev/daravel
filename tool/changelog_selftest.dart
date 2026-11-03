import 'dart:io';

import 'changelog.dart';

/// Tests of tool/changelog.dart, run in CI:
/// `dart run tool/changelog_selftest.dart`. The workspace root has no
/// `package:test`, so this is a plain program that exits 1 on a failure.
void main() {
  var failures = 0;
  void check(String name, Object? actual, Object? expected) {
    final ok = '$actual' == '$expected';
    if (!ok) {
      failures++;
      stderr.writeln('FAIL $name\n  expected: $expected\n  actual:   $actual');
    } else {
      stdout.writeln('ok   $name');
    }
  }

  const older = '## 1.0.0\n\n- First.\n';
  const head = '# Changelog\n\nIntro.\n\n';

  // The template is a valid, empty section.
  final empty = '$head$unreleasedTemplate$older';
  check('template has no problems', unreleasedProblems(empty), <String>[]);
  check('template has no notes', hasNotes(unreleasedBody(empty)!), false);
  check(
    'a missing section is reported',
    unreleasedProblems('$head$older').length,
    1,
  );
  check(
    'a missing sub-header is reported',
    unreleasedProblems(empty.replaceFirst('### Fixed\n', '')),
    ['"## Unreleased" in CHANGELOG.md lacks "### Fixed".'],
  );

  // Releasing keeps the notes, drops the empty parts, adds a new template.
  final withNotes = empty
      .replaceFirst('### Added\n\n', '### Added\n\n- A thing.\n\n')
      .replaceFirst('### Fixed\n\n', '### Fixed\n\n- A bug.\n\n');
  check(
    'release drops empty Changed and the empty label',
    releaseChangelog(withNotes, '1.1.0'),
    '$head$unreleasedTemplate'
        '## 1.1.0\n\n### Added\n\n- A thing.\n\n### Fixed\n\n- A bug.\n\n'
        '$older',
  );
  final withUpgrade = empty.replaceFirst(
    '$upgradeLabel\n\n',
    '$upgradeLabel\n\n- `X` is exported now.\n\n',
  );
  check(
    'release keeps Changed with its upgrade note',
    releaseChangelog(withUpgrade, '1.1.0'),
    '$head$unreleasedTemplate'
        '## 1.1.0\n\n### Changed\n\n$upgradeLabel\n\n- `X` is exported now.\n\n'
        '$older',
  );
  var refused = false;
  try {
    releaseChangelog(empty, '1.1.0');
  } on StateError {
    refused = true;
  }
  check('release refuses an empty section', refused, true);

  // A new export needs a new upgrade note.
  const diff =
      'diff --git a/packages/daravel/lib/daravel.dart b/packages/daravel/lib/daravel.dart\n'
      '--- a/packages/daravel/lib/daravel.dart\n'
      '+++ b/packages/daravel/lib/daravel.dart\n'
      '@@ -10,0 +11 @@\n'
      "+export 'src/database/legacy_key.dart';\n"
      " // context\n"
      "-export 'src/old.dart';\n";
  final added = addedExportsIn(diff);
  check('added exports are found', added, [
    "packages/daravel/lib/daravel.dart: export 'src/database/legacy_key.dart';",
  ]);
  check(
    'no new note is a problem',
    upgradeNoteProblems(
      baseChangelog: empty,
      headChangelog: empty,
      addedExports: added,
    ).length,
    1,
  );
  check(
    'a new note under the label passes',
    upgradeNoteProblems(
      baseChangelog: empty,
      headChangelog: withUpgrade,
      addedExports: added,
    ),
    <String>[],
  );
  check(
    'a note elsewhere does not count',
    upgradeNoteProblems(
      baseChangelog: empty,
      headChangelog: withNotes,
      addedExports: added,
    ).length,
    1,
  );
  check(
    'no export, no problem',
    upgradeNoteProblems(
      baseChangelog: empty,
      headChangelog: empty,
      addedExports: const [],
    ),
    <String>[],
  );

  if (failures > 0) {
    stderr.writeln('$failures failure(s).');
    exitCode = 1;
  }
}
