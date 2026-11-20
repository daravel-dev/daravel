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
        '## 1.1.0\n\n### Fixed\n\n- A bug.\n\n### Added\n\n- A thing.\n\n'
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

  // A release commit: tool/release.dart moved the notes under the version.
  final released = releaseChangelog(withUpgrade, '1.1.0');
  check(
    'a release with its note under the version passes',
    upgradeNoteProblems(
      baseChangelog: empty,
      headChangelog: released,
      addedExports: added,
      releasedVersion: '1.1.0',
    ),
    <String>[],
  );
  final releasedWithoutNote = releaseChangelog(withNotes, '1.1.0');
  check(
    'a release without a note under the version is a problem',
    upgradeNoteProblems(
      baseChangelog: empty,
      headChangelog: releasedWithoutNote,
      addedExports: added,
      releasedVersion: '1.1.0',
    ).length,
    1,
  );
  check(
    'a note under another version does not count',
    upgradeNoteProblems(
      baseChangelog: empty,
      headChangelog: released,
      addedExports: added,
      releasedVersion: '1.2.0',
    ).length,
    1,
  );
  check(
    'the same version and an empty Unreleased is a problem, as before',
    upgradeNoteProblems(
      baseChangelog: empty,
      headChangelog: released,
      addedExports: added,
    ).length,
    1,
  );
  check(
    'the version is read from version.dart',
    daravelVersionIn("const String daravelVersion = '1.27.6';\n"),
    '1.27.6',
  );

  _fragmentChecks(check, head, older, empty);

  if (failures > 0) {
    stderr.writeln('$failures failure(s).');
    exitCode = 1;
  }
}

/// Fragments (`changelog.d/`) and the patch order of a version's notes.
void _fragmentChecks(
  void Function(String, Object?, Object?) check,
  String head,
  String older,
  String empty,
) {
  Fragment fragment(String name, String text) {
    check(
      'fragment $name is valid',
      fragmentProblems('$name.md', text),
      <String>[],
    );
    return parseFragment(name, text);
  }

  String section(String changelog, String version) {
    final start = changelog.indexOf('## $version\n');
    final end = changelog.indexOf('\n## ', start + 1);
    return changelog.substring(start, end == -1 ? null : end + 1);
  }

  // Zero fragments: the hand-written notes, with an opening paragraph and a
  // "Security:" note, in the order of the patches.
  final byHand = empty
      .replaceFirst(
        '## Unreleased\n\n',
        '## Unreleased\n\nA patch. Upgrade every application.\n\n',
      )
      .replaceFirst('### Added\n\n', '### Added\n\n- `X.y`, new.\n\n')
      .replaceFirst(
        '$upgradeLabel\n\n',
        '$upgradeLabel\n\n- New public name: `X.y`.\n\n',
      )
      .replaceFirst(
        '### Fixed\n\n',
        '### Fixed\n\n- A bug.\n- Security: a hole, closed.\n'
            '  (a line under the note)\n\n',
      );
  check(
    'zero fragments: opening paragraph, Security, Fixed, Added, Changed',
    section(releaseChangelog(byHand, '1.27.8'), '1.27.8'),
    '## 1.27.8\n\n'
        'A patch. Upgrade every application.\n\n'
        '### Security\n\n- A hole, closed.\n  (a line under the note)\n\n'
        '### Fixed\n\n- A bug.\n\n'
        '### Added\n\n- `X.y`, new.\n\n'
        '### Changed\n\n$upgradeLabel\n\n- New public name: `X.y`.\n\n',
  );
  check(
    'a release leaves a fresh template on top',
    releaseChangelog(byHand, '1.27.8').startsWith('$head$unreleasedTemplate'),
    true,
  );

  // Fragments without a "Security:" prefix, under an empty Unreleased.
  final plain = [
    fragment('b-second', '### Fixed\n\n- Second fix.\n'),
    fragment(
      'a-first',
      '### Changed\n\n- Behaves otherwise.\n\n'
          '### Upgrade notes\n\n- Say so.\n\n'
          '### Fixed\n\n- First fix.\n',
    ),
  ];
  check(
    'fragments without a prefix: by file name, no Security section',
    section(releaseChangelog(empty, '1.27.8', fragments: plain), '1.27.8'),
    '## 1.27.8\n\n'
        '### Fixed\n\n- First fix.\n- Second fix.\n\n'
        '### Changed\n\n- Behaves otherwise.\n\n$upgradeLabel\n\n- Say so.\n\n',
  );
  check(
    'the body\'s own notes come before the fragments\'',
    section(
      releaseChangelog(byHand, '1.27.8', fragments: plain),
      '1.27.8',
    ).contains('### Fixed\n\n- A bug.\n- First fix.\n- Second fix.\n'),
    true,
  );

  // "Security:" from a fragment, from any section but the upgrade notes.
  final secure = [
    fragment(
      'c-hole',
      '### Fixed\n\n- Security: `Thing` leaked.\n- Plain fix.\n\n'
          '### Changed\n\n- Security: a default, tightened.\n\n'
          '### Upgrade notes\n\n- Security: stays an upgrade note.\n',
    ),
  ];
  check(
    'Security notes from fragments, prefix dropped, first letter upper '
        '(a fragment\'s in the order of its sections)',
    section(releaseChangelog(empty, '1.27.8', fragments: secure), '1.27.8'),
    '## 1.27.8\n\n'
        '### Security\n\n- A default, tightened.\n- `Thing` leaked.\n\n'
        '### Fixed\n\n- Plain fix.\n\n'
        '### Changed\n\n$upgradeLabel\n\n- Security: stays an upgrade note.\n\n',
  );
  var refused = false;
  try {
    releaseChangelog(empty, '1.27.8');
  } on StateError {
    refused = true;
  }
  check('zero fragments and no notes: refused', refused, true);

  // What a fragment may not be.
  check(
    'a fragment name that is not a slug',
    fragmentProblems('My Branch.md', '### Fixed\n\n- X.\n').length,
    1,
  );
  check(
    '"### Security" is not a fragment section (use the prefix)',
    fragmentProblems('x.md', '### Security\n\n- X.\n').length,
    1,
  );
  check(
    'text outside the lists',
    fragmentProblems('x.md', '### Fixed\n\nProse.\n- X.\n').length,
    1,
  );
  check(
    'a section without a note',
    fragmentProblems('x.md', '### Fixed\n\n### Added\n\n- X.\n'),
    ['changelog.d/x.md: "### Fixed" has no note.'],
  );
  check('an empty fragment', fragmentProblems('x.md', '\n'), [
    'changelog.d/x.md: the fragment has no notes.',
  ]);

  // An upgrade note in a fragment counts for a new export.
  const export = ["packages/daravel/lib/daravel.dart: export 'src/x.dart';"];
  check(
    'an upgrade note in a fragment passes',
    upgradeNoteProblems(
      baseChangelog: empty,
      headChangelog: empty,
      addedExports: export,
      headFragments: [fragment('x', '### Upgrade notes\n\n- New `X`.\n')],
    ),
    <String>[],
  );
  check(
    'a fragment without one does not',
    upgradeNoteProblems(
      baseChangelog: empty,
      headChangelog: empty,
      addedExports: export,
      headFragments: [fragment('x', '### Fixed\n\n- A bug.\n')],
    ).length,
    1,
  );

  // A `### Security` section written by hand under `## Unreleased` is kept
  // as `### Security` verbatim (first letter unchanged), and any other
  // unknown `### ` header is refused with its name and line number.
  final withSecurityHeader = empty.replaceFirst(
    '### Added\n\n',
    '### Security\n\n- `foo` rejects bad input.\n\n### Added\n\n- X.\n\n',
  );
  check(
    'hand-written ### Security under ## Unreleased is preserved verbatim',
    releaseChangelog(withSecurityHeader, '1.1.0'),
    '$head$unreleasedTemplate'
        '## 1.1.0\n\n### Security\n\n- `foo` rejects bad input.\n\n'
        '### Added\n\n- X.\n\n$older',
  );

  final withUnknownHeader = empty.replaceFirst(
    '### Added\n\n',
    '### Removed\n\n- Old thing.\n\n### Added\n\n- X.\n\n',
  );
  String? unknownError;
  try {
    releaseChangelog(withUnknownHeader, '1.1.0');
  } on StateError catch (e) {
    unknownError = '$e';
  }
  check(
    'unknown ### header under ## Unreleased is refused with name and line',
    unknownError != null &&
        unknownError.contains('### Removed') &&
        RegExp(r'\b7\b').hasMatch(unknownError),
    true,
  );

  // The released patches, rebuilt: their notes as fragments (Security
  // notes as "Security: " notes under Fixed) and their opening paragraph
  // by hand give back the section as released.
  final changelog = File('CHANGELOG.md').readAsStringSync();
  for (final version in ['1.27.5', '1.27.6', '1.27.7']) {
    final released = section(changelog, version);
    final intro = <String>[];
    final parts = <String, List<String>>{};
    String? part;
    for (final line in released.split('\n').skip(1)) {
      if (line.startsWith('### ')) {
        part = line.substring(4);
      } else if (line == upgradeLabel) {
        part = 'Upgrade notes';
      } else if (line.trim().isEmpty) {
        continue;
      } else if (part == null) {
        intro.add(line);
      } else {
        (parts[part] ??= []).add(line);
      }
    }
    // A Security note becomes "- Security: <note, first letter lower>";
    // the lines under it stay as they are.
    final fixed = [
      for (final note in parts['Security'] ?? const <String>[])
        note.startsWith('- ')
            ? '- $securityPrefix${note[2].toLowerCase()}${note.substring(3)}'
            : note,
      ...?parts['Fixed'],
    ];
    final sections = [
      ('Added', parts['Added'] ?? const <String>[]),
      ('Changed', parts['Changed'] ?? const <String>[]),
      ('Upgrade notes', parts['Upgrade notes'] ?? const <String>[]),
      ('Fixed', fixed),
    ];
    final opening = '## Unreleased\n\n${intro.join('\n')}\n\n';
    // A fragment holds only one-line notes; 1.27.6 wraps its notes, so it
    // is rebuilt from notes written by hand under `## Unreleased` instead.
    final oneLine = sections.every(
      (s) => s.$2.every((line) => line.startsWith('- ')),
    );
    final String rebuilt;
    if (oneLine) {
      final text = StringBuffer();
      for (final (name, lines) in sections) {
        if (lines.isNotEmpty) {
          text.write('### $name\n\n${lines.join('\n')}\n\n');
        }
      }
      rebuilt = releaseChangelog(
        empty.replaceFirst('## Unreleased\n\n', opening),
        version,
        fragments: [fragment('patch-${version.replaceAll('.', '-')}', '$text')],
      );
    } else {
      String lines(int i) =>
          sections[i].$2.isEmpty ? '' : '${sections[i].$2.join('\n')}\n\n';
      rebuilt = releaseChangelog(
        empty.replaceFirst(
          unreleasedTemplate,
          '$opening### Added\n\n${lines(0)}### Changed\n\n${lines(1)}'
          '$upgradeLabel\n\n${lines(2)}### Fixed\n\n${lines(3)}',
        ),
        version,
      );
    }
    check(
      '$version rebuilt (${oneLine ? 'one fragment' : 'by hand'}) is the '
      'section released',
      section(rebuilt, version),
      released,
    );
  }
}
