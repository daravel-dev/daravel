/// The `## Unreleased` section of CHANGELOG.md (Keputusan #04, KEP-04.3).
///
/// `main` always carries an `## Unreleased` section with the three
/// sub-headers of [unreleasedTemplate], so a pull request only adds lines
/// under one of them and two pull requests no longer both create the
/// section. `tool/release.dart` turns it into the version's section with
/// [releaseChangelog] and puts a fresh empty one above it.
library;

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
}) {
  if (addedExports.isEmpty) {
    return const [];
  }
  final before = upgradeNotes(baseChangelog);
  final after = upgradeNotes(headChangelog);
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
        'Say under "$upgradeLabel" in "## Unreleased" of CHANGELOG.md which '
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
/// notes under `## <version>`, without the sub-headers (and the upgrade
/// label) that stayed empty, and a fresh [unreleasedTemplate] above it.
String releaseChangelog(String changelog, String version) {
  final match = _unreleased.firstMatch(changelog);
  if (match == null || !hasNotes(match[1]!)) {
    throw StateError(
      'CHANGELOG.md has no notes under "## Unreleased"; write them first.',
    );
  }
  final released = '## $version\n\n${_withoutEmptyParts(match[1]!)}';
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
