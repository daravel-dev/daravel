import 'dart:io';

import 'docs/i18n.dart';

/// Prepares a release: one version for every package of the workspace
/// (Blueprint #12, part B).
///
/// ```bash
/// dart run tool/release.dart 1.9.0 \
///   --summary="Mail and notifications, DB_URL, ..." \
///   --summary-id="Mail dan notifikasi, DB_URL, ..."
/// ```
///
/// It sets the version of every workspace pubspec and their constraints on
/// each other, `daravelVersion`, the bug report template, turns
/// `## Unreleased` of CHANGELOG.md into `## <version>`, adds the version to
/// each package's CHANGELOG.md (unless it already has an entry), and adds
/// the summary to the release table of the guide in both languages. The
/// release notes themselves are written by hand under `## Unreleased`
/// before; the tool refuses to run without them.
///
/// Afterwards: review `git diff`, commit `Release <version>`, push, wait for
/// CI, then `git tag -a v<version>` and push the tag (publish.yml).
void main(List<String> args) {
  final version = args.where((a) => !a.startsWith('--')).firstOrNull;
  String? option(String name) => args
      .where((a) => a.startsWith('--$name='))
      .map((a) => a.substring(name.length + 3))
      .firstOrNull;
  if (version == null ||
      !RegExp(r'^\d+\.\d+\.\d+(-[\w.]+)?$').hasMatch(version)) {
    stderr.writeln(
      'Usage: dart run tool/release.dart <version> '
      '--summary="..." --summary-id="..."',
    );
    exitCode = 64;
    return;
  }
  final summary = option('summary');
  final summaryId = option('summary-id');
  if (summary == null || summaryId == null) {
    stderr.writeln(
      'Give --summary and --summary-id: one line for the release table of '
      'docs/guide/releases.md and docs/guide/id/releases.md.',
    );
    exitCode = 64;
    return;
  }

  final current = RegExp(
    r"daravelVersion = '([^']+)'",
  ).firstMatch(_read('packages/daravel/lib/src/foundation/version.dart'))![1]!;
  if (current == version) {
    stderr.writeln('The workspace is already at $version.');
    exitCode = 1;
    return;
  }
  final changelog = _read('CHANGELOG.md');
  final unreleased = RegExp(
    r'^## Unreleased\n(.*?)(?=^## )',
    multiLine: true,
    dotAll: true,
  ).firstMatch(changelog);
  if (unreleased == null || unreleased[1]!.trim().isEmpty) {
    stderr.writeln(
      'CHANGELOG.md has no notes under "## Unreleased"; write them first.',
    );
    exitCode = 1;
    return;
  }

  final members = _workspace();
  final names = [
    for (final member in members) _name(_read('$member/pubspec.yaml')),
  ];
  final dependency = RegExp(
    '^(\\s+(?:${names.join('|')})): \\^${RegExp.escape(current)}\$',
    multiLine: true,
  );
  for (final member in members) {
    final path = '$member/pubspec.yaml';
    _write(
      path,
      _read(path)
          .replaceFirst(
            RegExp('^version: ${RegExp.escape(current)}\$', multiLine: true),
            'version: $version',
          )
          .replaceAllMapped(dependency, (m) => '${m[1]}: ^$version'),
    );
  }
  _replace(
    'packages/daravel/lib/src/foundation/version.dart',
    "'$current'",
    "'$version'",
  );
  _replace(
    '.github/ISSUE_TEMPLATE/bug_report.yml',
    'placeholder: $current',
    'placeholder: $version',
  );
  _replace('CHANGELOG.md', '## Unreleased\n', '## $version\n');

  for (final member in members.where((m) => m.startsWith('packages/'))) {
    final path = '$member/CHANGELOG.md';
    final text = _read(path);
    if (!text.contains('## $version\n')) {
      _replace(
        path,
        '# Changelog\n\n',
        '# Changelog\n\n## $version\n\n'
            '- Version aligned with Daravel $version; see the '
            '[changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).\n\n',
      );
    }
  }

  final row = RegExp(r'^\| `[^`]+` \|', multiLine: true);
  for (final (path, text) in [
    ('docs/guide/releases.md', summary),
    ('docs/guide/id/releases.md', summaryId),
  ]) {
    final page = _read(path);
    final first = row.firstMatch(page)!;
    _write(
      path,
      page.replaceRange(first.start, first.start, '| `$version` | $text |\n'),
    );
  }
  // The table is in both languages, so the translation is current again.
  stampTranslation(Directory('docs/guide'), 'id/releases.md');

  stdout.writeln('''
Prepared $current → $version in ${members.length} packages.
Next:
  dart run tool/docs/generate.dart        # refresh the generated docs
  git diff                                # review, then:
  git commit -am "Release $version"
  git push                                # wait for CI, then:
  git tag -a v$version -m "Daravel $version" && git push origin v$version''');
}

List<String> _workspace() {
  final lines = _read('pubspec.yaml').split('\n');
  final start = lines.indexOf('workspace:');
  return [
    for (final line
        in lines.skip(start + 1).takeWhile((l) => l.startsWith('  - ')))
      line.substring(4).trim(),
  ];
}

String _name(String pubspec) =>
    RegExp(r'^name: (\S+)', multiLine: true).firstMatch(pubspec)![1]!;

String _read(String path) => File(path).readAsStringSync();

void _write(String path, String text) => File(path).writeAsStringSync(text);

void _replace(String path, String from, String to) {
  final text = _read(path);
  if (!text.contains(from)) {
    throw StateError('$path does not contain "$from".');
  }
  _write(path, text.replaceFirst(from, to));
}
