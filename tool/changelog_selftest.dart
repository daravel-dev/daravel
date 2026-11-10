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

  // Fragments (Blueprint #142).
  const fragmentText =
      '### Added\n\n- New thing.\n\n### Upgrade notes\n\n- `Y` is new.\n';
  check(
    'a valid fragment has no problems',
    fragmentProblems('a-branch.md', fragmentText),
    <String>[],
  );
  check(
    'a name that is not a slug is reported',
    fragmentProblems('My_Branch.md', fragmentText).length,
    1,
  );
  check(
    'an unknown header is reported',
    fragmentProblems('b.md', '### Removed\n\n- X.\n').length,
    1,
  );
  check(
    'a ## header is reported',
    fragmentProblems('b.md', '## 1.0.0\n\n### Added\n\n- X.\n').length,
    1,
  );
  check(
    'text outside the lists is reported',
    fragmentProblems('b.md', '### Added\n\nSome prose.\n- X.\n').length,
    1,
  );
  check(
    'a section without a note is reported',
    fragmentProblems('b.md', '### Added\n\n### Fixed\n\n- X.\n'),
    ['changelog.d/b.md: "### Added" has no note.'],
  );
  check('an empty fragment is reported', fragmentProblems('b.md', '\n'), [
    'changelog.d/b.md: the fragment has no notes.',
  ]);
  check(
    'a repeated header is reported',
    fragmentProblems('b.md', '### Added\n\n- X.\n\n### Added\n\n- Y.\n').length,
    1,
  );

  final first = parseFragment('b-second', fragmentText);
  final second = parseFragment(
    'a-first',
    '### Fixed\n\n- A fix.\n\n### Changed\n\n- A change.\n',
  );
  check('a fragment is parsed by section', first.lines, {
    'Added': ['- New thing.'],
    'Upgrade notes': ['- `Y` is new.'],
  });
  final assembled = assembleUnreleased(unreleasedBody(withNotes)!, [
    first,
    second,
  ]);
  check(
    'assembly: the changelog first, then fragments by name, in sections',
    assembled,
    '\n### Added\n\n- A thing.\n- New thing.\n\n'
        '### Changed\n\n- A change.\n\n'
        '$upgradeLabel\n\n- `Y` is new.\n\n'
        '### Fixed\n\n- A bug.\n- A fix.\n\n',
  );
  check(
    'assembly without fragments keeps the template shape',
    assembleUnreleased(unreleasedBody(empty)!, const []),
    unreleasedBody(empty),
  );
  check(
    'release with fragments only',
    releaseChangelog(empty, '1.1.0', fragments: [second]),
    '$head$unreleasedTemplate'
        '## 1.1.0\n\n### Changed\n\n- A change.\n\n### Fixed\n\n- A fix.\n\n'
        '$older',
  );
  check(
    'an upgrade note in a fragment counts for a new export',
    upgradeNoteProblems(
      baseChangelog: empty,
      headChangelog: empty,
      addedExports: added,
      headFragments: [first],
    ),
    <String>[],
  );
  check(
    'a fragment already on the base does not count again',
    upgradeNoteProblems(
      baseChangelog: empty,
      headChangelog: empty,
      addedExports: added,
      baseFragments: [first],
      headFragments: [first],
    ).length,
    1,
  );
  check(
    '--fragments-only sees notes added to CHANGELOG.md',
    addedUnreleasedNotes(empty, withNotes),
    ['- A thing.', '- A bug.'],
  );
  check(
    '--fragments-only lets older notes be',
    addedUnreleasedNotes(withNotes, withNotes),
    <String>[],
  );

  if (failures > 0) {
    stderr.writeln('$failures failure(s).');
    exitCode = 1;
  }
}
