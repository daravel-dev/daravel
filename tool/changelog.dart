/// The `## Unreleased` section of CHANGELOG.md (Keputusan #04, KEP-04.3).
///
/// `main` always carries an `## Unreleased` section with the three
/// sub-headers of [unreleasedTemplate], so a pull request only adds lines
/// under one of them and two pull requests no longer both create the
/// section. `tool/release.dart` turns it into the version's section with
/// [releaseChangelog] and puts a fresh empty one above it.
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

final RegExp _unreleased = RegExp(
  r'^## Unreleased\n(.*?)(?=^## )',
  multiLine: true,
  dotAll: true,
);

/// The text under `## Unreleased`, or `null` when there is no such section.
String? unreleasedBody(String changelog) =>
    _unreleased.firstMatch(changelog)?[1];

/// Whether [body] holds at least one note (a `- ` line).
bool hasNotes(String body) =>
    body.split('\n').any((line) => line.startsWith('- '));

/// What is wrong with the `## Unreleased` section of [changelog]: missing,
/// or without one of its sub-headers or the upgrade label.
List<String> unreleasedProblems(String changelog) {
  final body = unreleasedBody(changelog);
  if (body == null) {
    return ['CHANGELOG.md has no "## Unreleased" section above the releases.'];
  }
  return [
    for (final header in [
      '### Added',
      '### Changed',
      '### Fixed',
      upgradeLabel,
    ])
      if (!body.split('\n').contains(header))
        '"## Unreleased" in CHANGELOG.md lacks "$header".',
  ];
}

/// The notes listed under [upgradeLabel] in the `## Unreleased` section of
/// [changelog]: the `- ` lines after it, up to the next header.
List<String> upgradeNotes(String changelog) {
  final lines = (unreleasedBody(changelog) ?? '').split('\n');
  final start = lines.indexOf(upgradeLabel);
  if (start == -1) {
    return const [];
  }
  return [
    for (final line
        in lines.skip(start + 1).takeWhile((l) => !l.startsWith('#')))
      if (line.startsWith('- ')) line,
  ];
}

/// The problem when a pull request adds [addedExports] (lines that start
/// with `export` in a package's top-level library) but leaves the upgrade
/// notes of [baseChangelog] as they are in [headChangelog]: a new public
/// name can clash with a class of the same name in an application, as
/// `LegacyKey` did in 1.23.0.
List<String> upgradeNoteProblems({
  required String baseChangelog,
  required String headChangelog,
  required List<String> addedExports,
  List<Fragment> baseFragments = const [],
  List<Fragment> headFragments = const [],
}) {
  if (addedExports.isEmpty) {
    return const [];
  }
  final before = allUpgradeNotes(baseChangelog, baseFragments);
  final after = allUpgradeNotes(headChangelog, headFragments);
  final changed =
      before.length != after.length ||
      [for (var i = 0; i < after.length; i++) before[i] != after[i]]
          .any((c) => c);
  if (changed) {
    return const [];
  }
  return [
    'This change adds to a package\'s public API:\n'
        '${addedExports.map((e) => '  $e').join('\n')}\n'
        'Say which names are new under "### Upgrade notes" of your fragment '
        'in changelog.d/ (or under "$upgradeLabel" in "## Unreleased" of '
        'CHANGELOG.md), so an application with a class of the same name '
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
/// notes, with those of [fragments] ([assembleUnreleased]), under
/// `## <version>`, without the sub-headers (and the upgrade label) that
/// stayed empty, and a fresh [unreleasedTemplate] above it.
String releaseChangelog(
  String changelog,
  String version, {
  List<Fragment> fragments = const [],
}) {
  final match = _unreleased.firstMatch(changelog);
  if (match == null) {
    throw StateError('CHANGELOG.md has no "## Unreleased" section.');
  }
  final body = fragments.isEmpty
      ? match[1]!
      : assembleUnreleased(match[1]!, fragments);
  if (!hasNotes(body)) {
    throw StateError(
      'CHANGELOG.md has no notes under "## Unreleased" and changelog.d/ no '
      'fragment; write them first.',
    );
  }
  final released = '## $version\n\n${_withoutEmptyParts(body)}';
  return changelog.replaceRange(
    match.start,
    match.end,
    '$unreleasedTemplate$released',
  );
}

/// [body] without headers (`### ...`) and the upgrade label when no note
/// follows them before the next header, and without runs of blank lines.
String _withoutEmptyParts(String body) {
  // The text before the first sub-header, then one block per sub-header.
  final blocks = <List<String>>[[]];
  for (final line in body.split('\n')) {
    if (line.startsWith('### ')) {
      blocks.add([line]);
    } else {
      blocks.last.add(line);
    }
  }
  final kept = <String>[];
  for (final block in blocks) {
    var lines = block;
    final label = lines.indexOf(upgradeLabel);
    if (label != -1 && !lines.skip(label + 1).any((l) => l.startsWith('- '))) {
      lines = [...lines]..removeAt(label);
    }
    final header = lines.isNotEmpty && lines.first.startsWith('### ');
    final content = header ? lines.skip(1) : lines;
    if (!content.any((l) => l.trim().isNotEmpty)) {
      continue;
    }
    final text = lines.join('\n').trim();
    kept.add(text.replaceAll(RegExp(r'\n{3,}'), '\n\n'));
  }
  return '${kept.join('\n\n')}\n\n';
}

/// The sections a fragment may have, in the order they are assembled.
const List<String> fragmentSections = [
  'Added',
  'Changed',
  'Upgrade notes',
  'Fixed',
];

/// The directory of the fragments: `changelog.d/<slug>.md`, one per pull
/// request (Blueprint #142, ADR-038). `README.md` there explains the
/// format and is not a fragment.
const String fragmentsDirectory = 'changelog.d';

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
/// without a `- ` line, text outside the lists, a `## ` header, an empty
/// file.
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
  for (final (i, line) in text.split('\n').indexed) {
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
        '$where:${i + 1}: only "### " section headers belong in a fragment.',
      );
      continue;
    }
    if (section == null || !line.startsWith('- ')) {
      problems.add(
        '$where:${i + 1}: a fragment holds only "- " notes under its '
        'section headers.',
      );
      continue;
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
  for (final line in text.split('\n')) {
    if (line.startsWith('### ')) {
      section = line.substring(4).trim();
      lines.putIfAbsent(section, () => []);
    } else if (section != null && line.startsWith('- ')) {
      lines[section]!.add(line);
    }
  }
  return Fragment(name, lines);
}

/// The fragments of [directory], by name; [problems] receives what is
/// wrong with any of them (an invalid one is left out).
List<Fragment> readFragments(Directory directory, {List<String>? problems}) {
  if (!directory.existsSync()) {
    return const [];
  }
  final files = [
    for (final entity in directory.listSync())
      if (entity is File) entity,
  ]..sort((a, b) => a.uri.pathSegments.last.compareTo(b.uri.pathSegments.last));
  final fragments = <Fragment>[];
  for (final file in files) {
    final fileName = file.uri.pathSegments.last;
    if (fileName == 'README.md') {
      continue;
    }
    final text = file.readAsStringSync();
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

/// The notes of an `## Unreleased` [body], by section of
/// [fragmentSections] (`Upgrade notes`: those under [upgradeLabel]).
Map<String, List<String>> _unreleasedNotes(String body) {
  final notes = {for (final s in fragmentSections) s: <String>[]};
  String? section;
  for (final line in body.split('\n')) {
    if (line == '### Added') {
      section = 'Added';
    } else if (line == '### Changed') {
      section = 'Changed';
    } else if (line == upgradeLabel) {
      section = 'Upgrade notes';
    } else if (line == '### Fixed') {
      section = 'Fixed';
    } else if (line.startsWith('#')) {
      section = null;
    } else if (section != null && line.trim().isNotEmpty) {
      notes[section]!.add(line);
    }
  }
  return notes;
}

/// The `## Unreleased` [body] with [fragments] added: per section, its
/// own notes first, then the fragments' by file name, in each file's
/// order. The result has the shape of [unreleasedTemplate].
String assembleUnreleased(String body, List<Fragment> fragments) {
  final notes = _unreleasedNotes(body);
  final sorted = [...fragments]..sort((a, b) => a.name.compareTo(b.name));
  for (final fragment in sorted) {
    for (final section in fragmentSections) {
      notes[section]!.addAll(fragment.lines[section] ?? const []);
    }
  }
  String block(String header, String section) {
    final lines = notes[section]!;
    return lines.isEmpty ? '$header\n\n' : '$header\n\n${lines.join('\n')}\n\n';
  }

  return '\n'
      '${block('### Added', 'Added')}'
      '${block('### Changed', 'Changed')}'
      '${block(upgradeLabel, 'Upgrade notes')}'
      '${block('### Fixed', 'Fixed')}';
}

/// The upgrade notes of [changelog] and [fragments] together: what the
/// rule on new exports counts.
List<String> allUpgradeNotes(String changelog, List<Fragment> fragments) => [
  ...upgradeNotes(changelog),
  for (final fragment in [
    ...fragments,
  ]..sort((a, b) => a.name.compareTo(b.name)))
    ...?fragment.lines['Upgrade notes'],
];

/// The notes [headChangelog] adds to `## Unreleased` compared with
/// [baseChangelog]: what `--fragments-only` refuses.
List<String> addedUnreleasedNotes(String baseChangelog, String headChangelog) {
  final before = {
    for (final line in (unreleasedBody(baseChangelog) ?? '').split('\n'))
      if (line.startsWith('- ')) line,
  };
  return [
    for (final line in (unreleasedBody(headChangelog) ?? '').split('\n'))
      if (line.startsWith('- ') && !before.contains(line)) line,
  ];
}

/// `dart run tool/changelog.dart --preview`: prints `## Unreleased` of
/// CHANGELOG.md with the fragments of `changelog.d/` assembled, as the
/// next release will write it.
void main(List<String> args) {
  if (!args.contains('--preview')) {
    stderr.writeln('Usage: dart run tool/changelog.dart --preview');
    exitCode = 64;
    return;
  }
  final changelog = File('CHANGELOG.md').readAsStringSync();
  final problems = <String>[];
  final fragments = readFragments(
    Directory(fragmentsDirectory),
    problems: problems,
  );
  for (final problem in problems) {
    stderr.writeln(problem);
  }
  final body = unreleasedBody(changelog) ?? '';
  stdout.write('## Unreleased\n${assembleUnreleased(body, fragments)}');
  if (problems.isNotEmpty) {
    exitCode = 1;
  }
}
