/// The `## Unreleased` section of CHANGELOG.md (Keputusan #04, KEP-04.3).
///
/// `main` always carries an `## Unreleased` section with the three
/// sub-headers of [unreleasedTemplate], so a pull request only adds lines
/// under one of them and two pull requests no longer both create the
/// section. `tool/release.dart` turns it into the version's section with
/// [releaseChangelog] and puts a fresh empty one above it.
///
/// On `1.x` the notes can also come one file per pull request from
/// `changelog.d/` ([readFragments], the format of `main`), and a release
/// writes them in the order of the 1.27.x patches ([assembleRelease]).
///
/// Every line of the notes reaches the version's section exactly once, or
/// the input is refused with the file, the line number and the line
/// ([validateReleaseInput]): `--preview`, `tool/changelog_check.dart` and
/// `tool/release.dart` all go through that one function.
library;

import 'dart:io';

/// Says, under `### Changed`, what an upgrade can change for an
/// application. A pull request that adds a name to a package's public
/// library adds a line under it ([upgradeNoteProblems]).
const String upgradeLabel =
    '**Upgrading can change what an application sees:**';

/// The empty section `main` keeps at the top of CHANGELOG.md.
const String unreleasedTemplate =
    '## Unreleased\n'
    '\n'
    '### Added\n'
    '\n'
    '### Changed\n'
    '\n'
    '$upgradeLabel\n'
    '\n'
    '### Fixed\n'
    '\n';

/// [text] as the functions of this library read it: without a byte order
/// mark at its start and with `\n` line endings (for `\r\n`; normalizing
/// twice changes nothing more).
String normalizeChangelogText(String text) {
  final mark = String.fromCharCode(0xFEFF);
  final start = text.startsWith(mark) ? text.substring(1) : text;
  return start.replaceAll(_lineEnding, '\n');
}

final RegExp _lineEnding = RegExp(r'\r+\n');

/// Fenced code blocks, followed line by line as CommonMark reads them.
/// Inside one, `#` lines and `- ` lines are text of the note, not headers
/// or notes.
///
/// A block opens with a line whose text, after its indentation, starts
/// with at least three backticks or at least three tildes (an info string
/// may follow). Only a line of the same character, at least as many times
/// and with nothing after it but spaces, closes it: a shorter fence, the
/// other character, or a fence followed by text is a line of the block.
final class _Fences {
  String _character = '';
  int _length = 0;

  /// Whether the next line is inside a block.
  bool get inside => _length > 0;

  /// Outside a block: whether [line] opens one (and so is its first line).
  bool opens(String line) {
    final text = line.trimLeft();
    for (final character in const ['`', '~']) {
      var length = 0;
      while (length < text.length && text[length] == character) {
        length++;
      }
      if (length >= 3) {
        _character = character;
        _length = length;
        return true;
      }
    }
    return false;
  }

  /// Inside a block: reads [line], which closes the block or stays in it.
  void read(String line) {
    final text = line.trim();
    if (text.length >= _length &&
        text.split('').every((character) => character == _character)) {
      _length = 0;
    }
  }

  /// Reads [line]; whether it is a line of a code block (its fences too).
  bool takes(String line) {
    if (inside) {
      read(line);
      return true;
    }
    return opens(line);
  }
}

/// [line] in quotes for a message, a stray carriage return made visible.
String _quoted(String line) => '"${line.replaceAll('\r', r'\r')}"';

/// The header of a released version. Without the version the workspace is
/// at, `## Unreleased` is taken to end at the first of these.
final RegExp _versionHeader = RegExp(r'^## \d+\.\d+\.\d+([-+ ].*)?$');

/// What is wrong with [line] whatever it is: a carriage return that is not
/// part of a line ending would hide the text after it.
String? _carriageReturn(String where, String line) => line.contains('\r')
    ? '$where: ${_quoted(line)} holds a carriage return (shown as \\r) '
          'that is not part of a line ending; end the line there or remove it.'
    : null;

/// What is wrong with note [line] when it is `- Security: ` and no more:
/// there is nothing to put under `### Security`.
String? _emptySecurityNote(String where, String line) =>
    line.startsWith('- $securityPrefix') &&
        line.substring(2 + securityPrefix.length).trim().isEmpty
    ? '$where: ${_quoted(line)}: the note has no text after '
          '"$securityPrefix".'
    : null;

const String _noUnreleased =
    'CHANGELOG.md has no "## Unreleased" section above the releases.';

const String _noNotes =
    'CHANGELOG.md has no notes under "## Unreleased" and changelog.d/ no '
    'fragment; write them first.';

/// The `## Unreleased` section of a changelog, read once: where it is,
/// what is wrong with its lines, and its notes by section.
final class _Unreleased {
  _Unreleased(this.lines, this.start);

  /// The lines of the whole (normalized) file.
  final List<String> lines;

  /// The index in [lines] of `## Unreleased`.
  final int start;

  /// The index in [lines] of the next version's header, or `lines.length`
  /// when `## Unreleased` is the last section of the file.
  late final int end;

  /// What is wrong with a line, each with its 1-based line number.
  final List<String> problems = [];

  /// The sub-headers (and the upgrade label) the section has.
  final Set<String> headers = {};

  /// The opening paragraph: the text above the first sub-header.
  final List<String> intro = [];

  /// The lines of each section: notes, each followed by its own lines.
  final Map<String, List<String>> notes = {
    for (final s in ['Security', ...fragmentSections]) s: <String>[],
  };

  /// Adds note [line] of [section] where it belongs; returns that list.
  List<String> add(String section, String line) {
    if (section != 'Upgrade notes' &&
        section != 'Security' &&
        line.startsWith('- $securityPrefix')) {
      final rest = line.substring(2 + securityPrefix.length);
      final security = notes['Security']!;
      return security..add(
        rest.isEmpty ? '- ' : '- ${rest[0].toUpperCase()}${rest.substring(1)}',
      );
    }
    return notes[section]!..add(line);
  }

  /// The text under `## Unreleased`, as it is in the file.
  String get body =>
      lines.sublist(start + 1, end).map((line) => '$line\n').join();
}

/// Reads `## Unreleased` of [changelog] (normalized), or null when there
/// is none. Fenced code blocks are followed from the top of the file.
///
/// The section ends at the header of [currentVersion], the version the
/// workspace is at (`## 1.2.3`, a space and text may follow), or at the
/// end of the file; any other `## ` line under it is a problem, another
/// version's header too. Without [currentVersion] (for a reader that only
/// looks, and cannot know it) it ends at the first version header.
_Unreleased? _scan(String changelog, [String? currentVersion]) {
  final lines = changelog.split('\n');
  var start = -1;
  final fences = _Fences();
  for (var i = 0; i < lines.length; i++) {
    if (!fences.takes(lines[i]) && lines[i] == '## Unreleased') {
      start = i;
      break;
    }
  }
  if (start == -1) {
    return null;
  }
  final section = _Unreleased(lines, start);
  String where(int i) => 'CHANGELOG.md:${i + 1}: ${_quoted(lines[i])}';
  bool endsSection(String line) => currentVersion == null
      ? _versionHeader.hasMatch(line)
      : line == '## $currentVersion' || line.startsWith('## $currentVersion ');

  // The section a line belongs to; null above the first sub-header.
  String? current;
  // Under a header that was refused: its lines are not judged again.
  var refused = false;
  // The note the next continuation line belongs to.
  List<String>? last;
  // Where the lines of an open code block go (nowhere when the line that
  // opened it was refused).
  List<String>? block;
  var fenceStart = -1;
  var blankBefore = false;
  var end = lines.length;
  for (var i = start + 1; i < lines.length; i++) {
    final line = lines[i];
    if (fences.inside) {
      block?.add(line);
      fences.read(line);
      final stray = _carriageReturn('CHANGELOG.md:${i + 1}', line);
      if (stray != null) {
        section.problems.add(stray);
      }
      continue;
    }
    if (endsSection(line)) {
      end = i;
      break;
    }
    final stray = _carriageReturn('CHANGELOG.md:${i + 1}', line);
    if (stray != null) {
      // Not judged further: what follows the carriage return is hidden.
      section.problems.add(stray);
      blankBefore = false;
      continue;
    }
    if (line.trim().isEmpty) {
      blankBefore = true;
      continue;
    }
    final header = switch (line) {
      '### Security' => 'Security',
      '### Added' => 'Added',
      '### Changed' => 'Changed',
      upgradeLabel => 'Upgrade notes',
      '### Fixed' => 'Fixed',
      _ => null,
    };
    block = null;
    if (header != null) {
      current = header;
      refused = false;
      last = null;
      section.headers.add(line);
    } else if (line.startsWith('## ')) {
      section.problems.add(
        '${where(i)} under "## Unreleased" is neither a sub-header '
        '("### Security", "### Added", "### Changed", "### Fixed") nor '
        '${currentVersion == null ? 'the header of a released version '
                  '("## 1.2.3")' : 'the header that ends the section, '
                  '"## $currentVersion" (the version the workspace is at)'}.',
      );
      refused = true;
      last = null;
    } else if (line.startsWith('#')) {
      section.problems.add(
        'CHANGELOG.md:${i + 1}: unknown header ${_quoted(line)} under '
        '"## Unreleased" (expected "### Security", "### Added", '
        '"### Changed" or "### Fixed").',
      );
      refused = true;
      last = null;
    } else if (refused) {
      // Reported with its header.
    } else if (line.startsWith('* ')) {
      section.problems.add(
        '${where(i)}: a note starts with "- ", not with "* ".',
      );
    } else if (current == null) {
      section.intro.add(line);
      block = section.intro;
    } else if (line.startsWith('- ')) {
      final empty = current == 'Security' || current == 'Upgrade notes'
          ? null
          : _emptySecurityNote('CHANGELOG.md:${i + 1}', line);
      if (empty != null) {
        section.problems.add(empty);
      }
      last = section.add(current, line);
      block = last;
    } else if (last != null &&
        (line.startsWith(' ') || line.startsWith('\t') || !blankBefore)) {
      // A note's continuation line stays with the note.
      last.add(line);
      block = last;
    } else {
      section.problems.add(
        '${where(i)}: text under a sub-header is a "- " note or the '
        'continuation of one (indented, or on the line right after it); '
        'the opening paragraph goes above the first sub-header.',
      );
    }
    if (fences.opens(line)) {
      fenceStart = i;
    }
    blankBefore = false;
  }
  if (fences.inside) {
    section.problems.add(
      '${where(fenceStart)}: this code block is never closed.',
    );
  }
  section.end = end;
  return section;
}

/// The text under `## Unreleased`, or `null` when there is no such section.
/// The section ends at the header of [currentVersion] (see
/// [unreleasedInputProblems]) or, without it, at the first version header.
String? unreleasedBody(String changelog, {String? currentVersion}) =>
    _scan(normalizeChangelogText(changelog), currentVersion)?.body;

/// Whether [body] holds at least one note (a `- ` line outside a code
/// block).
bool hasNotes(String body) {
  final fences = _Fences();
  for (final line in normalizeChangelogText(body).split('\n')) {
    if (!fences.takes(line) && line.startsWith('- ')) {
      return true;
    }
  }
  return false;
}

/// What is wrong with the `## Unreleased` section of [changelog]: missing,
/// or without one of its sub-headers or the upgrade label.
List<String> unreleasedProblems(String changelog, {String? currentVersion}) {
  final section = _scan(normalizeChangelogText(changelog), currentVersion);
  if (section == null) {
    return [_noUnreleased];
  }
  return [
    for (final header in [
      '### Added',
      '### Changed',
      '### Fixed',
      upgradeLabel,
    ])
      if (!section.headers.contains(header))
        '"## Unreleased" in CHANGELOG.md lacks "$header".',
  ];
}

/// Everything wrong with the `## Unreleased` section of [changelog]: what
/// [unreleasedProblems] finds, and each line that a release could not
/// place, with its 1-based line number in `CHANGELOG.md` and its text:
///
/// - a `## ` line other than `## <currentVersion>` (a space and text may
///   follow it), the header of the version the workspace is at, where the
///   section ends: a header of another version would end it early or late
///   and leave notes out of the release;
/// - a `#` header other than `### Security`, `### Added`, `### Changed`
///   and `### Fixed`;
/// - a `* ` bullet;
/// - text under a sub-header that is neither a `- ` note nor the
///   continuation of one;
/// - a `- Security: ` note with nothing after the prefix;
/// - a carriage return that is not part of a line ending;
/// - a code block that is never closed.
///
/// Inside a fenced code block (backticks or tildes, closed by a fence of
/// the same character that is at least as long) every line is text of the
/// note it belongs to.
List<String> unreleasedInputProblems(
  String changelog, {
  required String currentVersion,
}) {
  final text = normalizeChangelogText(changelog);
  return [
    ...unreleasedProblems(text, currentVersion: currentVersion),
    ...?_scan(text, currentVersion)?.problems,
  ];
}

/// The notes listed under [upgradeLabel] in the `## Unreleased` section of
/// [changelog]: the `- ` lines after it, up to the next header.
List<String> upgradeNotes(String changelog, {String? currentVersion}) => [
  for (final line
      in _scan(
            normalizeChangelogText(changelog),
            currentVersion,
          )?.notes['Upgrade notes'] ??
          const <String>[])
    if (line.startsWith('- ')) line,
];

/// The `daravelVersion` declared in [source] (the text of
/// `packages/daravel/lib/src/foundation/version.dart`), or null.
String? daravelVersionIn(String source) =>
    RegExp(r"""const String daravelVersion = '([^']+)';""")
        .firstMatch(source)?[1];

/// The notes listed under [upgradeLabel] in the `## <version>` section of
/// [changelog], as [releaseChangelog] leaves them: the `- ` lines after the
/// label, up to the next header.
List<String> releasedUpgradeNotes(String changelog, String version) {
  final lines = normalizeChangelogText(changelog).split('\n');
  final section = lines.indexOf('## $version');
  if (section == -1) {
    return const [];
  }
  final body = lines
      .skip(section + 1)
      .takeWhile((l) => !l.startsWith('## '))
      .toList();
  final start = body.indexOf(upgradeLabel);
  if (start == -1) {
    return const [];
  }
  return [
    for (final line
        in body.skip(start + 1).takeWhile((l) => !l.startsWith('#')))
      if (line.startsWith('- ')) line,
  ];
}

/// The problem when a pull request adds [addedExports] (lines that start
/// with `export` in a package's top-level library) but leaves the upgrade
/// notes of [baseChangelog] as they are in [headChangelog]: a new public
/// name can clash with a class of the same name in an application, as
/// `LegacyKey` did in 1.23.0.
///
/// [releasedVersion] is set for a release commit (the version changed and
/// `## Unreleased` holds no note, as `tool/release.dart` leaves it): the
/// notes of [headChangelog] are then those under `## <releasedVersion>`,
/// where the release moved them, and no other version's.
///
/// The upgrade notes of [baseFragments] and [headFragments] (in
/// `changelog.d/`) count as well ([allUpgradeNotes]). [baseVersion] and
/// [headVersion] are the versions the workspace is at on either side,
/// where each `## Unreleased` ends.
List<String> upgradeNoteProblems({
  required String baseChangelog,
  required String headChangelog,
  required List<String> addedExports,
  String? releasedVersion,
  List<Fragment> baseFragments = const [],
  List<Fragment> headFragments = const [],
  String? baseVersion,
  String? headVersion,
}) {
  if (addedExports.isEmpty) {
    return const [];
  }
  final before = allUpgradeNotes(
    baseChangelog,
    baseFragments,
    currentVersion: baseVersion,
  );
  final after = releasedVersion == null
      ? allUpgradeNotes(
          headChangelog,
          headFragments,
          currentVersion: headVersion,
        )
      : releasedUpgradeNotes(headChangelog, releasedVersion);
  final changed =
      before.length != after.length ||
      [for (var i = 0; i < after.length; i++) before[i] != after[i]]
          .any((c) => c);
  if (changed) {
    return const [];
  }
  final section = releasedVersion == null
      ? '## Unreleased'
      : '## $releasedVersion';
  return [
    'This change adds to a package\'s public API:\n'
        '${addedExports.map((e) => '  $e').join('\n')}\n'
        'Say under "$upgradeLabel" in "$section" of CHANGELOG.md (or under '
        '"### Upgrade notes" of your fragment in changelog.d/) which '
        'names are new, so an application with a class of the same name '
        'knows to hide it in the import (see docs/guide/releases.md).',
  ];
}

/// The `export` lines a unified diff adds (`+export ...`), with their file.
List<String> addedExportsIn(String diff) {
  final added = <String>[];
  String? file;
  for (final line in diff.split('\n')) {
    if (line.startsWith('+++ ')) {
      file = line.startsWith('+++ b/') ? line.substring(6) : null;
    } else if (file != null &&
        line.startsWith('+') &&
        line.substring(1).trimLeft().startsWith('export ')) {
      added.add('$file: ${line.substring(1).trim()}');
    }
  }
  return added;
}

/// [changelog] with `## Unreleased` released as [version]: the section's
/// notes with those of [fragments], arranged by [assembleRelease], under
/// `## <version>`, without the sub-headers (and the upgrade label) that
/// stayed empty, and a fresh [unreleasedTemplate] above it.
///
/// [currentVersion] is the version the workspace is at, whose header ends
/// `## Unreleased`. Throws a [StateError] with the lines of
/// [unreleasedInputProblems] when there are any, and when there is no note
/// to release.
String releaseChangelog(
  String changelog,
  String version, {
  required String currentVersion,
  List<Fragment> fragments = const [],
}) {
  final text = normalizeChangelogText(changelog);
  final notes = assembleRelease(
    text,
    fragments,
    currentVersion: currentVersion,
  );
  if (!hasNotes(notes)) {
    throw StateError(_noNotes);
  }
  final section = _scan(text, currentVersion)!;
  final before = section.lines
      .sublist(0, section.start)
      .map((line) => '$line\n')
      .join();
  final after = section.lines.sublist(section.end).join('\n');
  final released = '$before$unreleasedTemplate## $version\n\n$notes';
  // As the last section of the file, it ends the file with one newline.
  return after.isEmpty ? '${released.trimRight()}\n' : '$released$after';
}

/// The sections a fragment may have (as on `main`).
const List<String> fragmentSections = [
  'Added',
  'Changed',
  'Upgrade notes',
  'Fixed',
];

/// The directory of the fragments: `changelog.d/<slug>.md`, one per pull
/// request (Blueprint #142, ADR-038). `README.md` there is not a fragment.
const String fragmentsDirectory = 'changelog.d';

/// The prefix of a note that [assembleRelease] puts under `### Security`.
const String securityPrefix = 'Security: ';

final RegExp _slug = RegExp(r'^[a-z0-9][a-z0-9-]*$');

/// One pull request's notes: [lines] by section of [fragmentSections].
final class Fragment {
  /// The fragment [name] (its slug) with [lines].
  const Fragment(this.name, this.lines);

  /// The slug: the file name without `.md`.
  final String name;

  /// The `- ` lines of each section, in the file's order.
  final Map<String, List<String>> lines;
}

/// What is wrong with fragment [fileName] holding [text]: a name that is
/// not a slug, a header other than those of [fragmentSections], a section
/// without a `- ` line, text outside the lists (a code block too: a
/// fragment's notes are one line each), a `## ` header, a `- Security: `
/// note with nothing after the prefix, a carriage return that is not part
/// of a line ending, an empty file. Each line's problem names the line and
/// its text.
List<String> fragmentProblems(String fileName, String text) {
  final problems = <String>[];
  final where = '$fragmentsDirectory/$fileName';
  if (!fileName.endsWith('.md') ||
      !_slug.hasMatch(fileName.substring(0, fileName.length - 3))) {
    problems.add(
      '$where: name it <slug>.md, the slug in lower case letters, digits '
      'and dashes (the branch name, say).',
    );
  }
  String? section;
  final counts = <String, int>{};
  final fences = _Fences();
  for (final (i, line) in normalizeChangelogText(text).split('\n').indexed) {
    final stray = _carriageReturn('$where:${i + 1}', line);
    if (stray != null) {
      problems.add(stray);
      continue;
    }
    if (fences.takes(line)) {
      if (line.trim().isEmpty) {
        continue;
      }
      problems.add(
        '$where:${i + 1}: ${_quoted(line)}: a fragment holds only "- " '
        'notes under its section headers.',
      );
      continue;
    }
    if (line.trim().isEmpty) {
      continue;
    }
    if (line.startsWith('### ')) {
      final name = line.substring(4).trim();
      if (!fragmentSections.contains(name)) {
        problems.add(
          '$where:${i + 1}: "### $name" is not a fragment section '
          '(${fragmentSections.map((s) => '"### $s"').join(', ')}).',
        );
      } else if (counts.containsKey(name)) {
        problems.add('$where:${i + 1}: "### $name" is there twice.');
      }
      section = name;
      counts[name] = 0;
      continue;
    }
    if (line.startsWith('#')) {
      problems.add(
        '$where:${i + 1}: ${_quoted(line)} is not a fragment section: only '
        '"### " section headers belong in a fragment '
        '(${fragmentSections.map((s) => '"### $s"').join(', ')}).',
      );
      continue;
    }
    if (section == null || !line.startsWith('- ')) {
      problems.add(
        '$where:${i + 1}: ${_quoted(line)}: a fragment holds only "- " '
        'notes under its section headers.',
      );
      continue;
    }
    final empty = section == 'Upgrade notes'
        ? null
        : _emptySecurityNote('$where:${i + 1}', line);
    if (empty != null) {
      problems.add(empty);
    }
    counts[section] = (counts[section] ?? 0) + 1;
  }
  if (counts.isEmpty) {
    problems.add('$where: the fragment has no notes.');
  }
  for (final MapEntry(:key, :value) in counts.entries) {
    if (value == 0 && fragmentSections.contains(key)) {
      problems.add('$where: "### $key" has no note.');
    }
  }
  return problems;
}

/// Fragment [name] from [text], which [fragmentProblems] found in order.
Fragment parseFragment(String name, String text) {
  final lines = <String, List<String>>{};
  String? section;
  for (final line in normalizeChangelogText(text).split('\n')) {
    if (line.startsWith('### ')) {
      section = line.substring(4).trim();
      lines.putIfAbsent(section, () => []);
    } else if (section != null && line.startsWith('- ')) {
      lines[section]!.add(line);
    }
  }
  return Fragment(name, lines);
}

/// The files of [directory] that are fragments, name → text, by name
/// (`README.md` is not one; none when there is no such directory).
Map<String, String> readFragmentFiles(Directory directory) {
  if (!directory.existsSync()) {
    return const {};
  }
  final files = [
    for (final entity in directory.listSync())
      if (entity is File) entity,
  ]..sort((a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last));
  return {
    for (final file in files)
      if (file.uri.pathSegments.last != 'README.md')
        file.uri.pathSegments.last: file.readAsStringSync(),
  };
}

/// The fragments of [directory], by name; [problems] receives what is
/// wrong with any of them (an invalid one is left out).
List<Fragment> readFragments(Directory directory, {List<String>? problems}) =>
    _fragments(readFragmentFiles(directory), problems);

List<Fragment> _fragments(Map<String, String> files, List<String>? problems) {
  final fragments = <Fragment>[];
  for (final MapEntry(key: fileName, value: text) in files.entries) {
    final found = fragmentProblems(fileName, text);
    if (found.isNotEmpty) {
      problems?.addAll(found);
      continue;
    }
    fragments.add(
      parseFragment(fileName.substring(0, fileName.length - 3), text),
    );
  }
  return fragments;
}

/// What a release reads: CHANGELOG.md and the fragments, checked.
final class ReleaseInput {
  /// The [changelog] and [fragments] with their [problems].
  const ReleaseInput(
    this.changelog,
    this.fragments,
    this.problems,
    this.currentVersion,
  );

  /// The text of CHANGELOG.md ([normalizeChangelogText]).
  final String changelog;

  /// The version the workspace is at: `## Unreleased` ends at its header.
  /// Null only when it could not be read, which is one of the [problems].
  final String? currentVersion;

  /// The valid fragments, in the order their files were given.
  final List<Fragment> fragments;

  /// What is wrong with the input, each with its file, and for a line its
  /// 1-based number and text. A release is refused unless this is empty.
  final List<String> problems;
}

/// The one check of what a release reads, for `--preview`,
/// `tool/changelog_check.dart` and `tool/release.dart`: the text of
/// CHANGELOG.md ([unreleasedInputProblems]) and of each fragment in
/// [fragmentFiles], file name → text ([fragmentProblems]). A byte order
/// mark at the start and `\r\n` line endings are read as if absent.
///
/// [currentVersion] is the version the workspace is at (`daravelVersion`):
/// `## Unreleased` ends at its header and at no other, so it is not
/// optional here, nor in [assembleRelease] and [releaseChangelog].
ReleaseInput validateReleaseInput(
  String changelog, {
  required String currentVersion,
  Map<String, String> fragmentFiles = const {},
}) {
  final text = normalizeChangelogText(changelog);
  final problems = unreleasedInputProblems(
    text,
    currentVersion: currentVersion,
  );
  final fragments = _fragments(fragmentFiles, problems);
  return ReleaseInput(text, fragments, problems, currentVersion);
}

/// Where `daravelVersion` is declared, from the root of the repository.
const String versionFile = 'packages/daravel/lib/src/foundation/version.dart';

/// [validateReleaseInput] of `CHANGELOG.md` and `changelog.d/` under
/// [root] (the current directory by default), with the version declared
/// in [versionFile] there.
ReleaseInput readReleaseInput({String root = '.'}) {
  final changelog = File('$root/CHANGELOG.md').readAsStringSync();
  final source = File('$root/$versionFile');
  final current = source.existsSync()
      ? daravelVersionIn(source.readAsStringSync())
      : null;
  if (current == null) {
    return ReleaseInput(normalizeChangelogText(changelog), const [], const [
      '$versionFile does not declare daravelVersion: the version the '
          'workspace is at says where "## Unreleased" of CHANGELOG.md ends.',
    ], null);
  }
  return validateReleaseInput(
    changelog,
    currentVersion: current,
    fragmentFiles: readFragmentFiles(Directory('$root/$fragmentsDirectory')),
  );
}

/// The upgrade notes of [changelog] and [fragments] together, in the order
/// [assembleRelease] writes them: what the rule on new exports counts.
List<String> allUpgradeNotes(
  String changelog,
  List<Fragment> fragments, {
  String? currentVersion,
}) => [
  ...upgradeNotes(changelog, currentVersion: currentVersion),
  for (final fragment in [
    ...fragments,
  ]..sort((a, b) => a.name.compareTo(b.name)))
    ...?fragment.lines['Upgrade notes'],
];

/// A version's notes from `## Unreleased` of [changelog] and [fragments],
/// in the order of the 1.27.x patches: the text before the first
/// sub-header (the opening paragraph, written by hand), then
/// `### Security`, `### Fixed`, `### Added` and `### Changed` with
/// [upgradeLabel] and the upgrade notes. In each section the changelog's
/// own notes come first, then the fragments' by file name. A note that
/// starts with [securityPrefix] goes under `### Security` without it, from
/// any section but the upgrade notes; a line under a note that does not
/// start a new one stays with it, a fenced code block as it is. A section
/// without a note is left out, and so is the label without an upgrade
/// note; blank lines outside code blocks are not kept.
///
/// A note written by hand under `### Security` is kept as it is: one that
/// starts with [securityPrefix] there keeps the prefix, unlike in the
/// other sections (so do the upgrade notes).
///
/// [currentVersion] is the version the workspace is at, whose header ends
/// `## Unreleased`. Throws a [StateError] with the lines of
/// [unreleasedInputProblems] when there are any: no line is dropped or
/// moved in silence.
String assembleRelease(
  String changelog,
  List<Fragment> fragments, {
  required String currentVersion,
}) {
  final text = normalizeChangelogText(changelog);
  final problems = unreleasedInputProblems(
    text,
    currentVersion: currentVersion,
  );
  if (problems.isNotEmpty) {
    throw StateError(problems.join('\n'));
  }
  final section = _scan(text, currentVersion)!;
  final sorted = [...fragments]..sort((a, b) => a.name.compareTo(b.name));
  for (final fragment in sorted) {
    for (final s in fragmentSections) {
      for (final line in fragment.lines[s] ?? const <String>[]) {
        section.add(s, line);
      }
    }
  }
  List<String> of(String name) => section.notes[name]!;
  final parts = [
    if (section.intro.isNotEmpty) section.intro.join('\n'),
    for (final name in ['Security', 'Fixed', 'Added'])
      if (of(name).isNotEmpty) '### $name\n\n${of(name).join('\n')}',
    if (of('Changed').isNotEmpty || of('Upgrade notes').isNotEmpty)
      [
        '### Changed',
        if (of('Changed').isNotEmpty) of('Changed').join('\n'),
        // The label stays as long as a line stands under it.
        if (of('Upgrade notes').isNotEmpty) ...[
          upgradeLabel,
          of('Upgrade notes').join('\n'),
        ],
      ].join('\n\n'),
  ];
  return parts.isEmpty
      ? ''
      : '${parts.map((p) => p.trimRight()).join('\n\n')}\n\n';
}

/// `dart run tool/changelog.dart --preview`: prints the notes the next
/// release writes from `## Unreleased` of CHANGELOG.md and the fragments
/// of `changelog.d/`, or what is wrong with them (exit code 1).
void main(List<String> args) {
  if (!args.contains('--preview')) {
    stderr.writeln('Usage: dart run tool/changelog.dart --preview');
    exitCode = 64;
    return;
  }
  exitCode = preview('.', stdout, stderr);
}

/// The preview of the repository under [root], to [out]; what is wrong
/// with the input to [err]. The exit code.
int preview(String root, StringSink out, StringSink err) {
  final input = readReleaseInput(root: root);
  for (final problem in input.problems) {
    err.writeln(problem);
  }
  final current = input.currentVersion;
  if (input.problems.isNotEmpty || current == null) {
    return 1;
  }
  final notes = assembleRelease(
    input.changelog,
    input.fragments,
    currentVersion: current,
  );
  out.write('## <next>\n\n$notes');
  return 0;
}
