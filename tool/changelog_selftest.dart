import 'dart:io';
import 'dart:math';

import 'changelog.dart';
import 'changelog_check.dart';
import 'release.dart';

/// Tests of tool/changelog.dart and tool/release.dart, run in CI:
/// `dart run tool/changelog_selftest.dart`. The workspace root has no
/// `package:test`, so this is a plain program that exits 1 on a failure.
Future<void> main() async {
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
    _release(withNotes, '1.1.0'),
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
    _release(withUpgrade, '1.1.0'),
    '$head$unreleasedTemplate'
        '## 1.1.0\n\n### Changed\n\n$upgradeLabel\n\n- `X` is exported now.\n\n'
        '$older',
  );
  var refused = false;
  try {
    _release(empty, '1.1.0');
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
  final released = _release(withUpgrade, '1.1.0');
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
  final releasedWithoutNote = _release(withNotes, '1.1.0');
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
  _inputChecks(check);
  _propertyChecks(check);
  _releaseChecks(check);
  await _entryPointChecks(check);

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
    section(_release(byHand, '1.27.8'), '1.27.8'),
    '## 1.27.8\n\n'
        'A patch. Upgrade every application.\n\n'
        '### Security\n\n- A hole, closed.\n  (a line under the note)\n\n'
        '### Fixed\n\n- A bug.\n\n'
        '### Added\n\n- `X.y`, new.\n\n'
        '### Changed\n\n$upgradeLabel\n\n- New public name: `X.y`.\n\n',
  );
  check(
    'a release leaves a fresh template on top',
    _release(byHand, '1.27.8').startsWith('$head$unreleasedTemplate'),
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
    section(_release(empty, '1.27.8', fragments: plain), '1.27.8'),
    '## 1.27.8\n\n'
        '### Fixed\n\n- First fix.\n- Second fix.\n\n'
        '### Changed\n\n- Behaves otherwise.\n\n$upgradeLabel\n\n- Say so.\n\n',
  );
  check(
    'the body\'s own notes come before the fragments\'',
    section(
      _release(byHand, '1.27.8', fragments: plain),
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
    section(_release(empty, '1.27.8', fragments: secure), '1.27.8'),
    '## 1.27.8\n\n'
        '### Security\n\n- A default, tightened.\n- `Thing` leaked.\n\n'
        '### Fixed\n\n- Plain fix.\n\n'
        '### Changed\n\n$upgradeLabel\n\n- Security: stays an upgrade note.\n\n',
  );
  var refused = false;
  try {
    _release(empty, '1.27.8');
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
    _release(withSecurityHeader, '1.1.0'),
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
    _release(withUnknownHeader, '1.1.0');
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
  for (final bad in ['#### Deep', '###Removed']) {
    final text = empty.replaceFirst(
      '### Added\n\n',
      '$bad\n\n- Note.\n\n### Added\n\n- X.\n\n',
    );
    String? err;
    try {
      _release(text, '1.1.0');
    } on StateError catch (e) {
      err = '$e';
    }
    check(
      'unknown header "$bad" under ## Unreleased is refused with name and line',
      err != null && err.contains(bad) && RegExp(r'\b7\b').hasMatch(err),
      true,
    );
  }

  // The released patches, rebuilt: their notes as fragments (Security
  // notes as "Security: " notes under Fixed) and their opening paragraph
  // by hand give back the section as released.
  final changelog = File('CHANGELOG.md').readAsStringSync();
  for (final (previous, version) in [
    ('1.27.4', '1.27.5'),
    ('1.27.5', '1.27.6'),
    ('1.27.6', '1.27.7'),
  ]) {
    // Above the version that was the current one before the release.
    final above = empty.replaceFirst('## 1.0.0\n', '## $previous\n');
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
      rebuilt = _release(
        above.replaceFirst('## Unreleased\n\n', opening),
        version,
        current: previous,
        fragments: [fragment('patch-${version.replaceAll('.', '-')}', '$text')],
      );
    } else {
      String lines(int i) =>
          sections[i].$2.isEmpty ? '' : '${sections[i].$2.join('\n')}\n\n';
      rebuilt = _release(
        above.replaceFirst(
          unreleasedTemplate,
          '$opening### Added\n\n${lines(0)}### Changed\n\n${lines(1)}'
          '$upgradeLabel\n\n${lines(2)}### Fixed\n\n${lines(3)}',
        ),
        version,
        current: previous,
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

/// The number of times [part] is in [text].
int _count(String text, String part) => part.allMatches(text).length;

/// A changelog with [unreleased] above one released version.
String _withOlder(String unreleased) =>
    '# Changelog\n\n$unreleased## 1.0.0\n\n### Fixed\n\n- Old release [OLD].\n';

/// Hostile input: every line of the notes is in the version's section
/// once, or the input is refused with the file, the line number and the
/// line, by `--preview`, the check and the release alike (they all call
/// [validateReleaseInput]; [releaseChangelog] refuses with the same text).
void _inputChecks(void Function(String, Object?, Object?) check) {
  // Refused: each of [naming] is in the problems, which the release
  // repeats word for word.
  void refused(
    String name,
    String changelog,
    List<String> naming, {
    Map<String, String> fragments = const {},
    String current = '1.0.0',
  }) {
    try {
      final input = _validate(
        changelog,
        fragments: fragments,
        current: current,
      );
      final text = input.problems.join('\n');
      check('$name: refused, naming the line', [
        for (final part in naming)
          if (!text.contains(part)) 'no <$part> in <$text>',
      ], <String>[]);
      if (fragments.isEmpty) {
        String? error;
        try {
          _release(changelog, '9.9.9', current: current);
        } on StateError catch (e) {
          error = e.message;
        }
        check('$name: the release refuses with the same text', error, text);
      }
    } on Object catch (e) {
      check('$name: refused', 'threw $e', 'problems');
    }
  }

  // Accepted: [markers] are in the section once each, in this order, and
  // once each in the released file, with the older release.
  String? accepted(
    String name,
    String changelog,
    List<String> markers, {
    Map<String, String> fragments = const {},
    String current = '1.0.0',
  }) {
    try {
      final input = _validate(
        changelog,
        fragments: fragments,
        current: current,
      );
      check('$name: accepted', input.problems, <String>[]);
      final section = _assemble(
        input.changelog,
        input.fragments,
        current: current,
      );
      check(
        '$name: every note once in the section, in order',
        [
          for (final marker in markers) _count(section, marker),
          for (var i = 1; i < markers.length; i++)
            section.indexOf(markers[i - 1]) < section.indexOf(markers[i]),
        ],
        [
          for (final _ in markers) 1,
          for (var i = 1; i < markers.length; i++) true,
        ],
      );
      final released = _release(
        changelog,
        '9.9.9',
        fragments: input.fragments,
        current: current,
      );
      check(
        '$name: every note once in the released file',
        [
          for (final marker in markers) _count(released, marker),
          _count(released, '[OLD]'),
          released.contains('\r'),
        ],
        [for (final _ in markers) 1, _count(changelog, '[OLD]'), false],
      );
      return section;
    } on Object catch (e) {
      check('$name: accepted', 'threw $e', 'a section');
      return null;
    }
  }

  const rest = '### Added\n\n### Changed\n\n$upgradeLabel\n\n### Fixed\n\n';
  const top = '### Added\n\n### Changed\n\n$upgradeLabel\n\n';

  // Headers the check let through.
  for (final header in [
    '### security',
    '###Security',
    '#### Security',
    '### Security ',
  ]) {
    refused(
      'header "$header"',
      _withOlder('## Unreleased\n\n$header\n\n- A note [N1].\n\n$rest'),
      ['CHANGELOG.md:5: unknown header "$header" under'],
    );
  }
  refused(
    'header "### Removed"',
    _withOlder('## Unreleased\n\n$rest### Removed\n\n- Dropped [N1].\n\n'),
    ['CHANGELOG.md:13: unknown header "### Removed" under'],
  );
  refused(
    'header "### Upgrade notes" in CHANGELOG.md',
    _withOlder(
      '## Unreleased\n\n### Added\n\n### Changed\n\n### Upgrade notes\n\n'
      '- Direct [N1].\n\n$upgradeLabel\n\n### Fixed\n\n',
    ),
    ['CHANGELOG.md:9: unknown header "### Upgrade notes" under'],
  );
  refused(
    'a "# " line at the start of a line of a note',
    _withOlder(
      '## Unreleased\n\n### Added\n\n- First note [N1]\n# comment [N2]\n\n'
      '### Changed\n\n$upgradeLabel\n\n### Fixed\n\n',
    ),
    ['CHANGELOG.md:8: unknown header "# comment [N2]" under'],
  );

  // A known header inside a code block is text of the note.
  final hijack = accepted(
    '"### Added" inside a code block',
    _withOlder(
      '## Unreleased\n\n$top### Fixed\n\n'
      '- Note before [N1]\n\n'
      '  ```markdown\n'
      '### Added\n'
      '  - Inside [N2]\n'
      '\n'
      '\n'
      '  ```\n\n'
      '- Note after [N3]\n\n',
    ),
    ['[N1]', '[N2]', '[N3]'],
  );
  check(
    'the block stays whole under "### Fixed"',
    hijack,
    '### Fixed\n\n- Note before [N1]\n  ```markdown\n### Added\n'
        '  - Inside [N2]\n\n\n  ```\n- Note after [N3]\n\n',
  );

  // Headers inside a code block are not headers. A block
  // that is not indented under its note, after an empty line, belongs to
  // no note: refused, by the line that opens it.
  refused(
    'a code block that belongs to no note',
    _withOlder(
      '## Unreleased\n\n$top### Fixed\n\n- A note [N1]:\n\n'
      '```markdown\n### Custom\n- inside [N2]\n```\n\n',
    ),
    ['CHANGELOG.md:15: "```markdown": text under a sub-header is'],
  );
  accepted(
    '"### Custom" inside a code block of a note',
    _withOlder(
      '## Unreleased\n\n$top### Fixed\n\n- A note [N1]:\n\n'
      '  ```markdown\n### Custom [N2]\n- inside [N3]\n  ```\n\n',
    ),
    ['[N1]', '[N2]', '[N3]'],
  );
  refused(
    'a code block with "## 2.0.0" that belongs to no note',
    _withOlder(
      '## Unreleased\n\n$top### Fixed\n\n- First fix [N1]:\n\n'
      '```markdown\n## 2.0.0\n- Example [N2]\n```\n\n- A fix after [N3]\n\n',
    ),
    ['CHANGELOG.md:15: "```markdown": text under a sub-header is'],
  );
  final fenced = accepted(
    '"## 2.0.0" inside a code block of a note',
    _withOlder(
      '## Unreleased\n\n$top### Fixed\n\n- First fix [N1]:\n'
      '  ```markdown\n## 2.0.0\n- Example [N2]\n  ```\n\n'
      '- A fix after [N3]\n\n',
    ),
    ['[N1]', '[N2]', '[N3]'],
  );
  check(
    '"## 2.0.0" in the block is kept, once',
    _count(fenced ?? '', '\n## 2.0.0\n'),
    1,
  );
  refused(
    'a code block that is never closed',
    _withOlder('## Unreleased\n\n$top### Fixed\n\n- A fix [N1]\n  ```dart\n'),
    ['CHANGELOG.md:14: "  ```dart": this code block is never closed.'],
  );

  // A "## " line that is not a version.
  refused(
    'a "## " line under "## Unreleased"',
    _withOlder(
      '## Unreleased\n\n### Fixed\n\n- Before [N1].\n\n'
      '## Breaking Notes\n\n- Hidden [N2].\n\n$top',
    ),
    ['CHANGELOG.md:9: "## Breaking Notes" under "## Unreleased" is neither'],
  );

  // "* " bullets and loose text.
  refused(
    'a "* " bullet and loose text',
    _withOlder(
      '## Unreleased\n\n### Added\n\n* Star [N1]\n\nLoose text [N2]\n\n'
      '### Changed\n\n$upgradeLabel\n\n* Upgrade star [N3]\n\n'
      '### Fixed\n\n- A fix [N4].\n\n',
    ),
    [
      'CHANGELOG.md:7: "* Star [N1]": a note starts with "- "',
      'CHANGELOG.md:9: "Loose text [N2]": text under a sub-header is',
      'CHANGELOG.md:15: "* Upgrade star [N3]": a note starts with "- "',
    ],
  );
  refused(
    'only a "* " bullet',
    _withOlder('## Unreleased\n\n$top### Fixed\n\n* Only star [N1].\n\n'),
    ['CHANGELOG.md:13: "* Only star [N1].": a note starts with "- "'],
  );
  refused(
    'a "* " bullet under the upgrade label',
    _withOlder(
      '## Unreleased\n\n$top* Upgrade via star [N1].\n\n'
      '### Fixed\n\n- A fix [N2].\n\n',
    ),
    ['CHANGELOG.md:11: "* Upgrade via star [N1].": a note starts with "- "'],
  );
  refused(
    'text under the upgrade label',
    _withOlder(
      '## Unreleased\n\n${top}Upgrade in prose [N1].\n\n'
      '### Fixed\n\n- A fix [N2].\n\n',
    ),
    ['CHANGELOG.md:11: "Upgrade in prose [N1].": text under a sub-header'],
  );
  final labelled = accepted(
    'the upgrade label with a note of several lines',
    _withOlder(
      '## Unreleased\n\n$top- Upgrading [N1]:\n  * nested [N2]\nnext line '
      '[N3]\n\n  after an empty line [N4]\n\n### Fixed\n\n',
    ),
    ['[N1]', '[N2]', '[N3]', '[N4]'],
  );
  check(
    'the label stays above every line under it',
    labelled,
    '### Changed\n\n$upgradeLabel\n\n- Upgrading [N1]:\n  * nested [N2]\n'
        'next line [N3]\n  after an empty line [N4]\n\n',
  );

  // Line endings.
  const endings =
      '## Unreleased\n\n### Security\n\n- Sec [N1].\n\n'
      '### Added\n\n### Changed\n\n$upgradeLabel\n\n### Fixed\n\n- Fix [N2].\n\n';
  accepted('CRLF line endings', _withOlder(endings).replaceAll('\n', '\r\n'), [
    '[N1]',
    '[N2]',
  ]);
  accepted(
    'CRLF on some lines',
    _withOlder(
      endings.replaceFirst(
        '### Security\n\n- Sec [N1].\n',
        '### Security\r\n\r\n- Sec [N1].\r\n',
      ),
    ),
    ['[N1]', '[N2]'],
  );
  refused(
    'a carriage return that is not a line ending',
    _withOlder(endings.replaceFirst('### Security\n\n', '### Security\r\r')),
    [
      'CHANGELOG.md:5: "### Security\\r\\r- Sec [N1]." holds a carriage '
          'return',
    ],
  );

  // "## Unreleased" is the last section of the file.
  const last =
      '# Changelog\n\n## Unreleased\n\n$top### Fixed\n\n- Initial note [N1].';
  for (final (name, text) in [
    ('without a newline at the end', last),
    ('with a newline at the end', '$last\n'),
  ]) {
    accepted('the last section, $name', text, ['[N1]']);
    String? released;
    try {
      released = _release(text, '9.9.9');
    } on StateError catch (e) {
      released = 'refused: ${e.message}';
    }
    check(
      'the last section, $name: released',
      released,
      '# Changelog\n\n$unreleasedTemplate'
          '## 9.9.9\n\n### Fixed\n\n- Initial note [N1].\n',
    );
  }

  // A byte order mark at the start of the text.
  final mark = String.fromCharCode(0xFEFF);
  final marked =
      '$mark## Unreleased\n\n$top### Fixed\n\n- A fix [N1].\n\n'
      '## 1.0.0\n\n- Old [OLD].\n';
  check(
    'a byte order mark: the section is found',
    unreleasedProblems(marked),
    <String>[],
  );
  accepted('a byte order mark', marked, ['[N1]']);

  // A fragment's wrong header is named.
  final empty = _withOlder(unreleasedTemplate);
  for (final header in ['###Fixed', '#### Fixed']) {
    refused(
      'fragment header "$header"',
      empty,
      ['changelog.d/bad.md:1: "$header" is not a fragment section'],
      fragments: {'bad.md': '$header\n\n- A note [N1].\n'},
    );
  }
  refused(
    'a code block in a fragment',
    empty,
    [
      'changelog.d/bad.md:4: "```": a fragment holds only',
      'changelog.d/bad.md:5: "### Added": a fragment holds only',
      'changelog.d/bad.md:6: "```": a fragment holds only',
    ],
    fragments: {'bad.md': '### Fixed\n\n- A note [N1].\n```\n### Added\n```\n'},
  );
  refused(
    'a "* " bullet in a fragment',
    empty,
    ['changelog.d/bad.md:3: "* A note [N1].": a fragment holds only'],
    fragments: {'bad.md': '### Fixed\n\n* A note [N1].\n'},
  );
  accepted(
    'a fragment with a byte order mark and CRLF line endings',
    empty,
    ['[N2]', '[N1]'],
    fragments: {
      'ok.md':
          '$mark### Fixed\r\n\r\n- A fix [N1].\r\n'
          '- Security: a hole [N2].\r\n',
    },
  );

  // Where "## Unreleased" ends: at the header of the version the workspace
  // is at, and at no other line.
  String upTo(String header, String notes) =>
      '# Changelog\n\n## Unreleased\n\n$top### Fixed\n\n$notes$header\n\n'
      '- Old [OLD].\n';
  refused(
    'a section of a later version under "## Unreleased"',
    upTo(
      '## 1.27.7',
      '- A fix [N1].\n\n## 1.27.8\n\n### Security\n\n- A hole [N2].\n\n',
    ),
    [
      'CHANGELOG.md:15: "## 1.27.8" under "## Unreleased" is neither',
      'the header that ends the section, "## 1.27.7" (the version',
    ],
    current: '1.27.7',
  );
  refused(
    'a line of a note that reads as a version header',
    upTo(
      '## 1.27.7',
      '- A fix [N1].\n## 2.0.0 will drop it\n\n- Another [N2].\n\n',
    ),
    ['CHANGELOG.md:14: "## 2.0.0 will drop it" under "## Unreleased" is'],
    current: '1.27.7',
  );
  refused(
    'the header of an older version than the workspace is at',
    upTo('## 1.27.6', '- A fix [N1].\n\n'),
    ['CHANGELOG.md:15: "## 1.27.6" under "## Unreleased" is neither'],
    current: '1.27.7',
  );
  refused(
    'a version that only starts like the one the workspace is at',
    upTo('## 1.27.70', '- A fix [N1].\n\n'),
    ['CHANGELOG.md:15: "## 1.27.70" under "## Unreleased" is neither'],
    current: '1.27.7',
  );
  accepted(
    'the header of the current version, followed by text',
    upTo('## 1.0.0-beta.1 (first release)', '- A fix [N1].\n\n'),
    ['[N1]'],
    current: '1.0.0-beta.1',
  );
  accepted(
    'the header of the current version inside a code block',
    upTo(
      '## 1.27.7',
      '- A fix [N1]:\n  ```\n## 1.27.7\ntext [N2]\n  ```\n- After [N3].\n\n',
    ),
    ['[N1]', '[N2]', '[N3]'],
    current: '1.27.7',
  );

  // Code blocks as CommonMark reads them: backticks or tildes, closed only
  // by a fence of the same character, at least as long, with no text.
  String fixed(String notes) =>
      _withOlder('## Unreleased\n\n$top### Fixed\n\n$notes\n');
  for (final (name, block) in [
    (
      'a block fenced with tildes',
      '~~~\n- Security: inside [N2]\n## 3.0.0\n~~~',
    ),
    (
      'a block of four backticks holding a fence of three',
      '````md\n```\n- Security: in code [N2]\n```\n````',
    ),
    (
      'a closing fence followed by text',
      '```\n``` not a close\n- Security: in code [N2]\n```',
    ),
    (
      'a closing fence longer than the opening one',
      '~~~\n- Security: inside [N2]\n```\n~~~~~',
    ),
  ]) {
    final section = accepted(
      name,
      fixed('- Example [N1]:\n$block\n- After [N3].\n'),
      ['[N1]', '[N2]', '[N3]'],
    );
    check(
      '$name: the block stays whole under its note',
      section,
      '### Fixed\n\n- Example [N1]:\n$block\n- After [N3].\n\n',
    );
  }
  refused(
    'a block that only a shorter fence follows',
    fixed('- Example [N1]:\n````\n```\n'),
    ['CHANGELOG.md:14: "````": this code block is never closed.'],
  );
  accepted(
    '"## Unreleased" inside a code block above the section',
    '# Changelog\n\n````\n```\n## Unreleased\n````\n\n'
        '## Unreleased\n\n$top### Fixed\n\n- A fix [N1].\n\n'
        '## 1.0.0\n\n- Old [OLD].\n',
    ['[N1]'],
  );
  check(
    'a "- " line inside a block of tildes is no note',
    hasNotes('~~~\n- inside\n~~~\n'),
    false,
  );
  refused(
    'a block of tildes in a fragment',
    empty,
    [
      'changelog.d/bad.md:4: "~~~": a fragment holds only',
      'changelog.d/bad.md:5: "### Added": a fragment holds only',
      'changelog.d/bad.md:6: "```": a fragment holds only',
      'changelog.d/bad.md:7: "~~~": a fragment holds only',
    ],
    fragments: {
      'bad.md': '### Fixed\n\n- A note [N1].\n~~~\n### Added\n```\n~~~\n',
    },
  );

  // A "- Security: " note without text, and a stray carriage return.
  refused('a "- Security: " note without text', fixed('- Security: \n'), [
    'CHANGELOG.md:13: "- Security: ": the note has no text after',
  ]);
  refused(
    'a "- Security: " note without text in a fragment',
    empty,
    ['changelog.d/bad.md:3: "- Security: ": the note has no text after'],
    fragments: {'bad.md': '### Fixed\n\n- Security: \n'},
  );
  refused(
    'a carriage return inside a line',
    fixed('- A fix [N1].\r- Another [N2].\n'),
    [
      'CHANGELOG.md:13: "- A fix [N1].\\r- Another [N2]." holds a carriage '
          'return',
    ],
  );
  refused(
    'a carriage return inside a line of a code block',
    fixed('- A fix [N1]:\n  ```\ncode\rmore\n  ```\n'),
    ['CHANGELOG.md:15: "code\\rmore" holds a carriage return'],
  );
  refused(
    'a carriage return inside a line of a fragment',
    empty,
    [
      'changelog.d/bad.md:3: "- A fix [N1].\\r- Another [N2]." holds a '
          'carriage return',
    ],
    fragments: {'bad.md': '### Fixed\n\n- A fix [N1].\r- Another [N2].\n'},
  );
}

/// [validateReleaseInput] at [current], the version the changelogs of
/// these tests end with unless they say otherwise.
ReleaseInput _validate(
  String changelog, {
  Map<String, String> fragments = const {},
  String current = '1.0.0',
}) => validateReleaseInput(
  changelog,
  currentVersion: current,
  fragmentFiles: fragments,
);

/// [assembleRelease] at [current].
String _assemble(
  String changelog,
  List<Fragment> fragments, {
  String current = '1.0.0',
}) => assembleRelease(changelog, fragments, currentVersion: current);

/// [releaseChangelog] at [current].
String _release(
  String changelog,
  String version, {
  List<Fragment> fragments = const [],
  String current = '1.0.0',
}) => releaseChangelog(
  changelog,
  version,
  currentVersion: current,
  fragments: fragments,
);

/// Generated input: each note carries a marker, and either every marker is
/// in the section once, in the order of the sections, or the input is
/// refused at exactly the lines generated as wrong.
void _propertyChecks(void Function(String, Object?, Object?) check) {
  final random = Random(438);
  final wrong = <String>[];
  var accepted = 0;
  var refused = 0;
  const runs = 400;
  final located = RegExp(r'^CHANGELOG\.md:(\d+): ');
  final marker = RegExp(r'\[M\d+\]');
  final shapes = {
    for (final shape in const [
      'backtick fence',
      'tilde fence',
      'fence of four backticks holding a shorter fence line',
      '"- Security: " note inside a fence',
      'fence at column 0 right under a note',
      'header of the current version',
      'header of the current version, followed by text',
      'header of another version outside a fence',
      'line of a note that reads as another version',
    ])
      shape: 0,
  };
  for (var run = 0; run < runs; run++) {
    final input = _GeneratedInput(random);
    for (final shape in input.shapes) {
      shapes[shape] = shapes[shape]! + 1;
    }
    void fail(String what) {
      if (wrong.length < 3) {
        wrong.add('run $run: $what\n${input.text}');
      }
    }

    try {
      final read = _validate(input.text, fragments: input.fragments);
      final lines = {
        for (final problem in read.problems)
          int.parse(located.firstMatch(problem)?[1] ?? '-1'),
      };
      String? error;
      String? released;
      try {
        released = _release(input.text, '9.9.9', fragments: read.fragments);
      } on StateError catch (e) {
        error = e.message;
      }
      if (input.wrongLines.isNotEmpty) {
        refused++;
        if ('${lines.toList()..sort()}' !=
            '${input.wrongLines.toList()..sort()}') {
          fail('refused at $lines, expected ${input.wrongLines}');
        } else if (error != read.problems.join('\n')) {
          fail('the release did not refuse with the same text: $error');
        }
        continue;
      }
      accepted++;
      if (read.problems.isNotEmpty) {
        fail('refused: ${read.problems}');
        continue;
      }
      final section = _assemble(read.changelog, read.fragments);
      final found = [for (final m in marker.allMatches(section)) m[0]!];
      if ('$found' != '${input.expected}') {
        fail('markers $found, expected ${input.expected}');
      } else if (released == null) {
        // Only an opening paragraph, or nothing at all: no note to release.
        if (hasNotes(section)) {
          fail('the release refused: $error');
        }
      } else if (marker.allMatches(released).length != found.length ||
          _count(released, '[OLD]') != _count(input.text, '[OLD]')) {
        fail('the released file does not hold every note once');
      }
    } on Object catch (e) {
      fail('threw $e');
    }
  }
  check(
    'generated input ($runs): every note once in its section, or refused '
        'at the wrong lines',
    wrong.join('\n'),
    '',
  );
  check(
    'generated input: both outcomes are well represented '
    '($accepted accepted, $refused refused)',
    accepted >= 100 && refused >= 100,
    true,
  );
  for (final MapEntry(key: shape, value: count) in shapes.entries) {
    check('generated input: $shape, in $count of $runs', count >= 15, true);
  }
}

/// One changelog and its fragments from a small grammar: sub-headers known
/// and unknown, `- ` and `* ` bullets, wrapped lines, code blocks holding
/// `#`, `##` and `###` lines, either line ending, with or without an older
/// section.
final class _GeneratedInput {
  _GeneratedInput(Random random) {
    final lines = ['# Changelog', '', '## Unreleased', ''];
    var markers = 0;
    String marker() => '[M${markers++}]';
    final notes = {
      for (final s in ['Intro', 'Security', ...fragmentSections]) s: <String>[],
    };
    bool chance(int percent) => random.nextInt(100) < percent;
    void wrongLine(String line) {
      lines.add(line);
      wrongLines.add(lines.length);
    }

    void codeBlock(String indent, List<String> into) {
      // The fence, and fence lines that do not close it: shorter ones, the
      // other character, or one followed by text.
      final (fence, inner, shape) = switch (random.nextInt(4)) {
        0 => ('```', const ['~~~', '``` not a close'], 'backtick fence'),
        1 => ('~~~', const ['```', '~~~ not a close'], 'tilde fence'),
        2 => (
          '````',
          const ['```', '```dart'],
          'fence of four backticks holding a shorter fence line',
        ),
        _ => ('~~~~~', const ['~~~', '~~~~', '`````'], 'tilde fence'),
      };
      shapes.add(shape);
      lines.add('$indent$fence${chance(50) ? 'markdown' : ''}');
      for (var i = random.nextInt(4) + 1; i > 0; i--) {
        final m = marker();
        into.add(m);
        final kind = i == 1 && fence == '````' ? 8 : random.nextInt(10);
        lines.add(switch (kind) {
          0 => '### Added',
          1 => '## 1.0.0',
          2 => '# comment $m',
          3 => '- inner $m',
          4 => '* star $m',
          5 => '',
          6 => '$upgradeLabel $m',
          7 => '- Security: inner $m',
          8 => inner[random.nextInt(inner.length)],
          _ => '## 2.0.0',
        });
        if (kind == 7) {
          shapes.add('"- Security: " note inside a fence');
        }
        if (!lines.last.contains(m)) {
          lines.add('text $m');
        }
      }
      // A closing fence may be longer than the opening one.
      lines.add('$indent$fence${chance(20) ? fence[0] : ''}');
    }

    if (chance(50)) {
      final m = marker();
      notes['Intro']!.add(m);
      lines.add('An opening paragraph $m');
      if (chance(30)) {
        codeBlock('', notes['Intro']!);
      }
      lines.add('');
    }
    final sections = [
      if (chance(40)) ('### Security', 'Security'),
      ('### Added', 'Added'),
      ('### Changed', 'Changed'),
      (upgradeLabel, 'Upgrade notes'),
      ('### Fixed', 'Fixed'),
    ];
    final unknownAt = chance(15) ? random.nextInt(sections.length + 1) : -1;
    void unknownHeader() {
      wrongLine(
        const [
          '### Removed',
          '#### Fixed',
          '###Added',
          '## Notes',
          '# Top',
          '### fixed',
          '## 2.0.0',
          '## 1.0.1',
          '## 1.0.0-beta.1',
          '## 1.0.00',
        ][random.nextInt(10)],
      );
      if (lines.last.startsWith('## ') && lines.last != '## Notes') {
        shapes.add('header of another version outside a fence');
      }
      lines.addAll(['', '- Under it ${marker()}', '']);
    }

    for (final (i, (header, name)) in sections.indexed) {
      if (i == unknownAt) {
        unknownHeader();
      }
      lines.addAll([header, '']);
      var hasNote = false;
      for (var n = random.nextInt(4); n > 0; n--) {
        final m = marker();
        final moved =
            name != 'Security' && name != 'Upgrade notes' && chance(15);
        final into = notes[moved ? 'Security' : name]!..add(m);
        lines.add(moved ? '- Security: a note $m' : '- A note $m');
        hasNote = true;
        if (chance(12)) {
          shapes.add('fence at column 0 right under a note');
          codeBlock('', into);
        }
        if (chance(25)) {
          final w = marker();
          into.add(w);
          lines.add('  wrapped $w');
        }
        if (chance(15)) {
          final w = marker();
          into.add(w);
          lines.add('not indented, right under it $w');
        }
        if (chance(15)) {
          final w = marker();
          into.add(w);
          lines.add('  * nested $w');
        }
        if (chance(25)) {
          if (chance(50)) {
            lines.add('');
          }
          codeBlock('  ', into);
        }
        if (chance(50)) {
          lines.add('');
        }
      }
      if (chance(5)) {
        wrongLine('* A star bullet ${marker()}');
      }
      if (chance(5)) {
        lines.add('');
        wrongLine('Loose text ${marker()}');
      }
      if (chance(4)) {
        // A code block that belongs to no note: its first line is wrong.
        lines.add('');
        wrongLine('```');
        lines.addAll(['### Fixed', '- inside ${marker()}', '```']);
      }
      if (!hasNote && chance(4)) {
        wrongLine('  indented under no note ${marker()}');
      }
      if (chance(5)) {
        // Reads as the header of another version: what follows it in the
        // section is not judged.
        shapes.add('line of a note that reads as another version');
        wrongLine('## 2.0.0 will drop it ${marker()}');
        lines.add('- The rest of it ${marker()}');
      }
      lines.add('');
    }
    if (unknownAt == sections.length) {
      unknownHeader();
    }
    if (chance(70)) {
      // The header of the version the tests are at ends the section.
      final dated = chance(30);
      shapes.add(
        dated
            ? 'header of the current version, followed by text'
            : 'header of the current version',
      );
      lines.addAll([
        dated ? '## 1.0.0 (2026-01-01)' : '## 1.0.0',
        '',
        '- Old [OLD].',
      ]);
    }
    var all = '${lines.join('\n')}${chance(70) ? '\n' : ''}';
    if (chance(30)) {
      all = all.replaceAll('\n', '\r\n');
    }
    text = chance(15) ? '${String.fromCharCode(0xFEFF)}$all' : all;

    // Fragments, by name: their notes follow the changelog's own.
    for (var f = random.nextInt(3); f > 0; f--) {
      final buffer = StringBuffer();
      for (final name in fragmentSections) {
        if (!chance(50)) {
          continue;
        }
        buffer.write('### $name\n\n');
        for (var n = random.nextInt(2) + 1; n > 0; n--) {
          final m = marker();
          final moved = name != 'Upgrade notes' && chance(20);
          notes[moved ? 'Security' : name]!.add(m);
          buffer.write(moved ? '- Security: fragment $m\n' : '- Fragment $m\n');
        }
        buffer.write('\n');
      }
      if (buffer.isNotEmpty) {
        final file = '$buffer';
        fragments['f${3 - f}.md'] = chance(30)
            ? file.replaceAll('\n', '\r\n')
            : file;
      }
    }
    expected = [
      for (final name in [
        'Intro',
        'Security',
        'Fixed',
        'Added',
        'Changed',
        'Upgrade notes',
      ])
        ...notes[name]!,
    ];
  }

  /// The text of CHANGELOG.md.
  late final String text;

  /// The fragments, file name → text.
  final Map<String, String> fragments = {};

  /// The 1-based numbers of the lines that must be refused.
  final Set<int> wrongLines = {};

  /// The shapes this input holds, for the count over all inputs.
  final Set<String> shapes = {};

  /// The markers in the order the section must hold them.
  late final List<String> expected;
}

/// A release that is refused leaves every file as it was (the release is
/// run on a small workspace of its own, in a temporary git repository).
void _releaseChecks(void Function(String, Object?, Object?) check) {
  // Runs a release after [prepare]; whether the tree stayed as it was.
  void refusedUntouched(
    String name,
    void Function(Directory root) prepare,
    String naming, {
    bool commit = true,
  }) {
    final root = _workspace();
    try {
      prepare(root);
      if (commit) {
        _commit(root, 'A prepared workspace');
      }
      final before = _snapshot(root);
      final errors = StringBuffer();
      final code = release(
        root.path,
        '1.0.1',
        summary: 'A patch',
        summaryId: 'Sebuah patch',
        out: StringBuffer(),
        err: errors,
      );
      check(
        'release, $name: refused, naming it',
        [code != 0, '$errors'.contains(naming) ? naming : '$errors'],
        [true, naming],
      );
      check('release, $name: no file changed', _snapshot(root) == before, true);
    } on Object catch (e) {
      check('release, $name: refused', 'threw $e', 'an exit code');
    } finally {
      _delete(root);
    }
  }

  File file(Directory root, String path) => File('${root.path}/$path');
  refusedUntouched(
    'a fragment git does not track',
    (root) => file(
      root,
      'changelog.d/c-untracked.md',
    ).writeAsStringSync('### Fixed\n\n- Not committed [R9].\n'),
    'changelog.d/c-untracked.md is not tracked by git',
    commit: false,
  );
  refusedUntouched(
    'a fragment with a change that is not committed',
    (root) => file(
      root,
      'changelog.d/a-fix.md',
    ).writeAsStringSync('### Fixed\n\n- Fragment fix [R2], edited.\n'),
    '"git rm" would refuse the fragments',
    commit: false,
  );
  // A release runs only on a tree without uncommitted changes: its commit
  // holds what the tool wrote and nothing else.
  refusedUntouched(
    'a tracked file with a change that is not committed',
    (root) => file(
      root,
      'packages/extra/example/main.dart',
    ).writeAsStringSync('void main() {} // edited\n'),
    'commit or stash these first.\n M packages/extra/example/main.dart\n',
    commit: false,
  );
  refusedUntouched(
    'notes in CHANGELOG.md that are not committed',
    (root) => file(root, 'CHANGELOG.md').writeAsStringSync(
      file(root, 'CHANGELOG.md').readAsStringSync().replaceFirst(
        '- By hand [R1].\n',
        '- By hand [R1].\n- Another by hand [R8].\n',
      ),
    ),
    'commit or stash these first.\n M CHANGELOG.md\n',
    commit: false,
  );
  refusedUntouched(
    'a change that is staged',
    (root) {
      file(root, 'notes.txt').writeAsStringSync('Staged.\n');
      _git(root, ['add', 'notes.txt']);
    },
    'commit or stash these first.\nA  notes.txt\n',
    commit: false,
  );
  refusedUntouched(
    'a package changelog without its header',
    (root) => file(
      root,
      'packages/extra/CHANGELOG.md',
    ).writeAsStringSync('Notes without a header.\n'),
    'packages/extra/CHANGELOG.md has no "# Changelog" header',
  );
  refusedUntouched(
    'a missing release page',
    (root) => file(root, 'docs/guide/id/releases.md').deleteSync(),
    'docs/guide/id/releases.md is missing.',
  );
  refusedUntouched(
    'a release page without its table',
    (root) =>
        file(root, 'docs/guide/releases.md').writeAsStringSync('# Releases\n'),
    'docs/guide/releases.md has no release table',
  );
  refusedUntouched(
    'a bug report template without the version',
    (root) => file(
      root,
      '.github/ISSUE_TEMPLATE/bug_report.yml',
    ).writeAsStringSync('placeholder: none\n'),
    '.github/ISSUE_TEMPLATE/bug_report.yml does not contain',
  );
  refusedUntouched(
    'a pubspec at another version',
    (root) => file(
      root,
      'packages/extra/pubspec.yaml',
    ).writeAsStringSync('name: extra\nversion: 0.9.0\n'),
    'packages/extra/pubspec.yaml has no "version: 1.0.0" line.',
  );
  refusedUntouched(
    'a missing package changelog',
    (root) => file(root, 'packages/daravel/CHANGELOG.md').deleteSync(),
    'packages/daravel/CHANGELOG.md is missing.',
  );
  const star = '# Changelog\n\n$unreleasedTemplate* A star [R1].\n';
  refusedUntouched(
    'input the check refuses',
    (root) => file(root, 'CHANGELOG.md').writeAsStringSync(star),
    _validate(star).problems.firstOrNull ?? 'a problem',
  );

  // And one that goes through, from the first check to the last file. A
  // file git does not track is no change to a tracked one.
  final root = _workspace();
  try {
    file(root, 'untracked.txt').writeAsStringSync('Not a fragment.\n');
    final errors = StringBuffer();
    final code = release(
      root.path,
      '1.0.1',
      summary: 'A patch',
      summaryId: 'Sebuah patch',
      out: StringBuffer(),
      err: errors,
    );
    check('release: a valid workspace is released', '$code $errors', '0 ');
    String read(String path) {
      final f = file(root, path);
      return f.existsSync() ? f.readAsStringSync() : '(missing)';
    }

    check(
      'release: the notes, once each, under the version',
      read('CHANGELOG.md'),
      '# Changelog\n\n$unreleasedTemplate'
          '## 1.0.1\n\n'
          '### Security\n\n- A hole [R3].\n\n'
          '### Fixed\n\n- By hand [R1].\n- Fragment fix [R2].\n\n'
          '### Changed\n\n$upgradeLabel\n\n- New name [R4].\n\n'
          '## 1.0.0\n\n- First.\n',
    );
    check(
      'release: versions, constraints and the release tables',
      [
        read('packages/daravel/lib/src/foundation/version.dart')
            .contains("'1.0.1'"),
        read('packages/daravel/pubspec.yaml').contains('version: 1.0.1'),
        read('packages/extra/pubspec.yaml').contains('daravel: ^1.0.1'),
        read('apps/demo/pubspec.yaml').contains('version: 1.0.1'),
        read('.github/ISSUE_TEMPLATE/bug_report.yml').contains('1.0.1'),
        read('packages/daravel/CHANGELOG.md').contains('## 1.0.1\n'),
        read('packages/extra/CHANGELOG.md').contains('## 1.0.1\n'),
        read('docs/guide/releases.md').contains('| `1.0.1` | A patch |\n'),
        read('docs/guide/id/releases.md')
            .contains('| `1.0.1` | Sebuah patch |\n'),
        read('docs/guide/id/releases.md').contains('sha256:000000000000'),
      ],
      [true, true, true, true, true, true, true, true, true, false],
    );
    final status = _git(root, ['status', '--porcelain', '--', 'changelog.d']);
    check(
      'release: the fragments are removed with git rm',
      status.replaceAll('\r', ''),
      'D  changelog.d/a-fix.md\nD  changelog.d/b-new.md\n',
    );
    final before = _snapshot(root);
    final again = release(
      root.path,
      '1.0.1',
      summary: 'A patch',
      summaryId: 'Sebuah patch',
      out: StringBuffer(),
      err: StringBuffer(),
    );
    check(
      'release: a second run is refused and changes nothing',
      [again != 0, _snapshot(root) == before],
      [true, true],
    );
  } on Object catch (e) {
    check('release: a valid workspace is released', 'threw $e', 'released');
  } finally {
    _delete(root);
  }
}

/// The three entry points refuse the same input with the same text: the
/// preview, the check and the release, each run on a workspace whose
/// committed CHANGELOG.md holds a header of another version under
/// `## Unreleased`.
Future<void> _entryPointChecks(
  void Function(String, Object?, Object?) check,
) async {
  const top =
      '# Changelog\n\n## Unreleased\n\n### Added\n\n### Changed\n\n'
      '$upgradeLabel\n\n### Fixed\n\n';
  for (final (name, changelog, naming) in [
    (
      'a section of a later version under "## Unreleased"',
      '$top- By hand [R1].\n\n## 1.0.1\n\n### Security\n\n- A hole [R5].\n\n'
          '## 1.0.0\n\n- First.\n',
      'CHANGELOG.md:15: "## 1.0.1" under "## Unreleased" is neither',
    ),
    (
      'a line of a note that reads as a version header',
      '$top- By hand [R1].\n## 2.0.0 will drop it\n\n- Another [R5].\n\n'
          '## 1.0.0\n\n- First.\n',
      'CHANGELOG.md:14: "## 2.0.0 will drop it" under "## Unreleased" is',
    ),
  ]) {
    final root = _workspace(replace: {'CHANGELOG.md': changelog});
    try {
      final problems = _validate(
        changelog,
        fragments: readFragmentFiles(Directory('${root.path}/changelog.d')),
      ).problems;
      final text = problems.map((p) => '$p\n').join();
      final before = _snapshot(root);
      final previewErrors = StringBuffer();
      final previewCode = preview(root.path, StringBuffer(), previewErrors);
      final checkErrors = StringBuffer();
      final checkCode = await checkChangelog(
        root.path,
        'HEAD',
        StringBuffer(),
        checkErrors,
      );
      final releaseErrors = StringBuffer();
      final releaseCode = release(
        root.path,
        '1.0.1',
        summary: 'A patch',
        summaryId: 'Sebuah patch',
        out: StringBuffer(),
        err: releaseErrors,
      );
      check(
        'entry points, $name: the input is refused, naming the line',
        [problems.length, text.contains(naming) ? naming : text],
        [1, naming],
      );
      check(
        'entry points, $name: the preview refuses with that text',
        '$previewCode $previewErrors',
        '1 $text',
      );
      check(
        'entry points, $name: the check refuses with that text',
        '$checkCode $checkErrors',
        '1 $text',
      );
      check(
        'entry points, $name: the release refuses with that text',
        '$releaseCode $releaseErrors',
        '1 Fix these before the release:\n'
            '${problems.map((p) => '- $p\n').join()}'
            'No file was changed.\n',
      );
      check(
        'entry points, $name: no file changed',
        _snapshot(root) == before,
        true,
      );
    } on Object catch (e) {
      check('entry points, $name: refused', 'threw $e', 'three refusals');
    } finally {
      _delete(root);
    }
  }
}

/// Commits everything under [root] as [message].
void _commit(Directory root, String message) {
  _git(root, ['add', '-A']);
  _git(root, [
    '-c',
    'user.name=Self-test',
    '-c',
    'user.email=selftest@example.com',
    '-c',
    'commit.gpgsign=false',
    'commit',
    '-q',
    '-m',
    message,
  ]);
}

/// A workspace of two packages and an application at 1.0.0, with a note
/// by hand and two fragments, committed in a git repository of its own;
/// [replace] gives other texts for some of its files.
Directory _workspace({Map<String, String> replace = const {}}) {
  final root = Directory.systemTemp.createTempSync('daravel_release_');
  const files = {
    'pubspec.yaml':
        'name: workspace\nworkspace:\n  - packages/daravel\n'
        '  - packages/extra\n  - apps/demo\n',
    'packages/daravel/pubspec.yaml': 'name: daravel\nversion: 1.0.0\n',
    'packages/daravel/lib/src/foundation/version.dart':
        "const String daravelVersion = '1.0.0';\n",
    'packages/daravel/CHANGELOG.md': '# Changelog\n\n## 1.0.0\n\n- First.\n',
    'packages/daravel/example/main.dart': 'void main() {}\n',
    'packages/extra/pubspec.yaml':
        'name: extra\nversion: 1.0.0\ndependencies:\n  daravel: ^1.0.0\n',
    'packages/extra/CHANGELOG.md': '# Changelog\n\n## 1.0.0\n\n- First.\n',
    'packages/extra/example/main.dart': 'void main() {}\n',
    'apps/demo/pubspec.yaml':
        'name: demo\nversion: 1.0.0\npublish_to: none\n'
        'dependencies:\n  daravel: ^1.0.0\n',
    '.github/ISSUE_TEMPLATE/bug_report.yml': '      placeholder: 1.0.0\n',
    '.github/workflows/publish.yml':
        'jobs:\n  publish:\n    steps:\n'
        '      - run: dart pub publish --force\n'
        '        working-directory: packages/daravel\n'
        '      - run: dart pub publish --force\n'
        '        working-directory: packages/extra\n',
    'CHANGELOG.md':
        '# Changelog\n\n## Unreleased\n\n### Added\n\n### Changed\n\n'
        '$upgradeLabel\n\n### Fixed\n\n- By hand [R1].\n\n'
        '## 1.0.0\n\n- First.\n',
    'changelog.d/a-fix.md': '### Fixed\n\n- Fragment fix [R2].\n',
    'changelog.d/b-new.md':
        '### Added\n\n- Security: a hole [R3].\n\n'
        '### Upgrade notes\n\n- New name [R4].\n',
    'docs/guide/releases.md':
        '# Releases\n\n| Version | Summary |\n| --- | --- |\n'
        '| `1.0.0` | First |\n',
    'docs/guide/id/releases.md':
        '<!-- source: releases.md sha256:000000000000 -->\n# Rilis\n\n'
        '| Versi | Ringkasan |\n| --- | --- |\n| `1.0.0` | Pertama |\n',
  };
  for (final MapEntry(key: path, value: text) in {
    ...files,
    ...replace,
  }.entries) {
    File('${root.path}/$path')
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(text);
  }
  _git(root, ['init', '-q']);
  _git(root, ['config', 'core.autocrlf', 'false']);
  _commit(root, 'A workspace at 1.0.0');
  return root;
}

String _git(Directory root, List<String> args) {
  final result = Process.runSync('git', args, workingDirectory: root.path);
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout as String;
}

/// Every file under [root] with its text, and what git says of the tree.
String _snapshot(Directory root) {
  final files = [
    for (final entity in root.listSync(recursive: true))
      if (entity is File &&
          !entity.path.replaceAll(r'\', '/').contains('/.git/'))
        entity,
  ]..sort((a, b) => a.path.compareTo(b.path));
  return [
    for (final file in files) '${file.path}\n${file.readAsStringSync()}',
    _git(root, ['status', '--porcelain']),
  ].join('\n--\n');
}

/// Removes [root]; git's object files are read-only on Windows.
void _delete(Directory root) {
  try {
    if (Platform.isWindows) {
      Process.runSync('attrib', ['-R', '${root.path}\\*', '/S', '/D']);
    }
    root.deleteSync(recursive: true);
  } on FileSystemException {
    // A leftover temporary directory fails no check.
  }
}
