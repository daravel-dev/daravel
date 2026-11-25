import 'dart:io';

import 'changelog.dart';
import 'docs/i18n.dart';
import 'publish_checks.dart';

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
/// `## Unreleased` of CHANGELOG.md into `## <version>`, does the same in
/// each package's CHANGELOG.md or else adds the version there (unless it
/// already has an entry), and adds
/// the summary to the release table of the guide in both languages. The
/// release notes themselves are written by hand under `## Unreleased`, or
/// one fragment per pull request in `changelog.d/` (assembled into the
/// version and removed with `git rm`), before; the tool refuses to run
/// without them. The version's notes follow the 1.27.x patches: the
/// opening paragraph (text above the first sub-header of
/// `## Unreleased`, written by hand; `--summary` is only the release
/// table's line), then `### Security` (notes that start with
/// `Security: `), `### Fixed`, `### Added`, `### Changed`. Sub-headers
/// left empty are dropped, and a fresh empty `## Unreleased`
/// (tool/changelog.dart) goes back on top.
///
/// Everything is checked before the first file is written ([planRelease]):
/// a release that is refused leaves the tree as it was.
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
  exitCode = release(
    Directory.current.path,
    version,
    summary: summary,
    summaryId: summaryId,
  );
}

const String _bugReport = '.github/ISSUE_TEMPLATE/bug_report.yml';
const String _releases = 'docs/guide/releases.md';
const String _releasesId = 'docs/guide/id/releases.md';

/// What a release of the workspace under a root directory would do,
/// worked out without writing anything ([planRelease]).
final class ReleasePlan {
  /// A plan from [current] with [writes] and [fragments], or [problems].
  const ReleasePlan({
    required this.current,
    required this.members,
    required this.writes,
    required this.fragments,
    required this.problems,
  });

  /// The version the workspace is at (null when it could not be read).
  final String? current;

  /// The workspace members, as the root pubspec lists them.
  final List<String> members;

  /// The files to write, path (from the root) → new text.
  final Map<String, String> writes;

  /// The fragments to remove with `git rm`, paths from the root.
  final List<String> fragments;

  /// Why the release cannot run. Nothing is written unless it is empty.
  final List<String> problems;
}

/// Checks everything a release of [version] under [root] relies on and
/// works out every file it writes, without changing a file:
///
/// - `daravelVersion` is declared and is not [version] yet;
/// - no tracked file has a change that is not committed: the release
///   commit contains only what the tool writes;
/// - CHANGELOG.md and the fragments pass `validateReleaseInput` and hold a
///   note;
/// - every fragment is tracked by git and `git rm` would take it (no
///   uncommitted change);
/// - every workspace pubspec is there with its `name:` and the current
///   `version:` line; the bug report template has its placeholder;
/// - every package's CHANGELOG.md is there with `## Unreleased`, the
///   version, or the `# Changelog` header the entry goes under;
/// - both release pages of the guide are there with a row in their table.
ReleasePlan planRelease(
  String root,
  String version, {
  required String summary,
  required String summaryId,
}) {
  final problems = <String>[];
  final writes = <String, String>{};
  String? read(String path) {
    final file = File('$root/$path');
    if (!file.existsSync()) {
      problems.add('$path is missing.');
      return null;
    }
    return file.readAsStringSync();
  }

  ReleasePlan plan({
    String? current,
    List<String> members = const [],
    List<String> fragments = const [],
  }) => ReleasePlan(
    current: current,
    members: members,
    writes: writes,
    fragments: fragments,
    problems: problems,
  );

  final versionSource = read(versionFile);
  final current = versionSource == null
      ? null
      : daravelVersionIn(versionSource);
  if (current == null) {
    if (versionSource != null) {
      problems.add('$versionFile does not declare daravelVersion.');
    }
    return plan();
  }
  if (current == version) {
    problems.add('The workspace is already at $version.');
    return plan(current: current);
  }

  problems.addAll(_uncommittedChanges(root));

  // The notes: CHANGELOG.md and one fragment per pull request (as on main).
  String? changelog;
  var fragments = const <String>[];
  if (File('$root/CHANGELOG.md').existsSync()) {
    final input = readReleaseInput(root: root);
    problems.addAll(input.problems);
    if (input.problems.isEmpty) {
      try {
        changelog = releaseChangelog(
          input.changelog,
          version,
          currentVersion: current,
          fragments: input.fragments,
        );
      } on StateError catch (e) {
        problems.add(e.message);
      }
      fragments = [
        for (final f in input.fragments) '$fragmentsDirectory/${f.name}.md',
      ];
      problems.addAll(_fragmentRemovalProblems(root, fragments));
    }
  } else {
    problems.add('CHANGELOG.md is missing.');
  }

  final members = _workspace(read('pubspec.yaml') ?? '');
  if (members.isEmpty) {
    problems.add('pubspec.yaml lists no workspace member under "workspace:".');
  }
  final pubspecs = <String, String>{};
  final names = <String>[];
  for (final member in members) {
    final path = '$member/pubspec.yaml';
    final text = read(path);
    if (text == null) {
      continue;
    }
    final name = RegExp(r'^name: (\S+)', multiLine: true).firstMatch(text)?[1];
    if (name == null) {
      problems.add('$path has no "name:" line.');
      continue;
    }
    pubspecs[path] = text;
    names.add(name);
  }
  final ownVersion = RegExp(
    '^version: ${RegExp.escape(current)}\$',
    multiLine: true,
  );
  final dependency = RegExp(
    '^(\\s+(?:${names.map(RegExp.escape).join('|')})): '
    '\\^${RegExp.escape(current)}\$',
    multiLine: true,
  );
  for (final MapEntry(key: path, value: text) in pubspecs.entries) {
    if (!ownVersion.hasMatch(text)) {
      problems.add('$path has no "version: $current" line.');
      continue;
    }
    writes[path] = text
        .replaceFirst(ownVersion, 'version: $version')
        .replaceAllMapped(dependency, (m) => '${m[1]}: ^$version');
  }
  writes[versionFile] = versionSource!.replaceFirst("'$current'", "'$version'");
  final bugReport = read(_bugReport);
  if (bugReport != null) {
    if (bugReport.contains('placeholder: $current')) {
      writes[_bugReport] = bugReport.replaceFirst(
        'placeholder: $current',
        'placeholder: $version',
      );
    } else {
      problems.add('$_bugReport does not contain "placeholder: $current".');
    }
  }
  // The notes become the version's; an empty `## Unreleased` stays on top.
  if (changelog != null) {
    writes['CHANGELOG.md'] = changelog;
  }

  for (final member in members.where((m) => m.startsWith('packages/'))) {
    final path = '$member/CHANGELOG.md';
    var text = read(path);
    if (text == null) {
      continue;
    }
    // Notes written ahead under `## Unreleased` become the version's.
    if (text.contains('## Unreleased\n') && !text.contains('## $version\n')) {
      text = text.replaceFirst('## Unreleased\n', '## $version\n');
    }
    if (!text.contains('## $version\n')) {
      if (!text.contains('# Changelog\n\n')) {
        problems.add(
          '$path has no "# Changelog" header followed by an empty line '
          '(the entry of $version goes under it), nor "## Unreleased" or '
          '"## $version".',
        );
        continue;
      }
      text = text.replaceFirst(
        '# Changelog\n\n',
        '# Changelog\n\n## $version\n\n'
            '- Version aligned with Daravel $version; see the '
            '[changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).\n\n',
      );
    }
    writes[path] = text;
  }

  final row = RegExp(r'^\| `[^`]+` \|', multiLine: true);
  for (final (path, text) in [(_releases, summary), (_releasesId, summaryId)]) {
    final page = read(path);
    if (page == null) {
      continue;
    }
    final first = row.firstMatch(page);
    if (first == null) {
      problems.add('$path has no release table (a "| `1.2.3` | ... |" row).');
      continue;
    }
    writes[path] = page.replaceRange(
      first.start,
      first.start,
      '| `$version` | $text |\n',
    );
  }
  return plan(current: current, members: members, fragments: fragments);
}

/// The problem when a tracked file under [root] has a change that is not
/// committed (staged or not): the release commit holds only what the tool
/// writes, and the commands printed after a failure half-way restore
/// files to their committed state, which must then be the state the
/// release started from. Files git does not track do not count (a
/// fragment among them is refused by [_fragmentRemovalProblems]).
List<String> _uncommittedChanges(String root) {
  final status = Process.runSync('git', [
    'status',
    '--porcelain',
    '--untracked-files=no',
  ], workingDirectory: root);
  if (status.exitCode != 0) {
    return [
      '"git status" failed, so the tree cannot be checked for changes that '
          'are not committed:\n${'${status.stderr}'.trimRight()}',
    ];
  }
  final changes = '${status.stdout}'.trimRight();
  return [
    if (changes.isNotEmpty)
      'The tree has changes that are not committed. The release commit '
          'must contain only what the tool writes: commit or stash these '
          'first.\n$changes',
  ];
}

/// Why `git rm` would not remove [fragments] (paths under [root]): one
/// that git does not track, or one with a change that is not committed.
List<String> _fragmentRemovalProblems(String root, List<String> fragments) {
  final problems = <String>[];
  for (final path in fragments) {
    final tracked = Process.runSync('git', [
      'ls-files',
      '--error-unmatch',
      '--',
      path,
    ], workingDirectory: root);
    if (tracked.exitCode != 0) {
      problems.add(
        '$path is not tracked by git: commit it first (the release removes '
        'the fragments with "git rm").',
      );
    }
  }
  if (problems.isEmpty && fragments.isNotEmpty) {
    final removable = Process.runSync('git', [
      'rm',
      '--dry-run',
      '-q',
      '--',
      ...fragments,
    ], workingDirectory: root);
    if (removable.exitCode != 0) {
      problems.add(
        '"git rm" would refuse the fragments; commit or discard their '
        'changes first:\n${'${removable.stderr}'.trimRight()}',
      );
    }
  }
  return problems;
}

/// Releases [version] in the workspace under [root]; the exit code. What
/// it says goes to [out] and [err] (stdout and stderr by default).
///
/// Nothing is written unless [planRelease] and the publish checks find no
/// problem. The fragments are removed first, so a `git rm` that still
/// fails leaves every file as it was; should a write fail after that, the
/// message lists what was modified and how to restore it. The release
/// starts from a tree without uncommitted changes to tracked files
/// ([planRelease]), so those commands discard only what the tool wrote,
/// never an edit of the user's.
int release(
  String root,
  String version, {
  required String summary,
  required String summaryId,
  StringSink? out,
  StringSink? err,
}) {
  final errors = err ?? stderr;
  final plan = planRelease(
    root,
    version,
    summary: summary,
    summaryId: summaryId,
  );
  if (plan.current == version) {
    errors.writeln('The workspace is already at $version.');
    return 1;
  }
  // A package without an example or a publish step, or published before
  // its dependencies, loses pub points (Blueprint #55).
  final publish = plan.current == null
      ? const <String>[]
      : publishProblems(root);
  if (publish.isNotEmpty) {
    errors.writeln(
      'Fix these before the release (dart run tool/publish_checks.dart):',
    );
    for (final problem in publish) {
      errors.writeln('- $problem');
    }
  }
  if (plan.problems.isNotEmpty) {
    errors.writeln('Fix these before the release:');
    for (final problem in plan.problems) {
      errors.writeln('- $problem');
    }
  }
  if (publish.isNotEmpty || plan.problems.isNotEmpty) {
    errors.writeln('No file was changed.');
    return 1;
  }

  // The fragments are now the version's notes: they leave with the release
  // commit.
  const restoreFragments =
      'git restore --staged --worktree -- $fragmentsDirectory';
  if (plan.fragments.isNotEmpty) {
    final removed = Process.runSync('git', [
      'rm',
      '-q',
      '--',
      ...plan.fragments,
    ], workingDirectory: root);
    if (removed.exitCode != 0) {
      errors.writeln(
        'git rm of the fragments failed: ${removed.stderr}\n'
        'No other file was changed. If "git status" shows fragments as '
        'deleted, bring them back with:\n'
        '  $restoreFragments',
      );
      return 1;
    }
  }
  final written = <String>[];
  try {
    for (final MapEntry(key: path, value: text) in plan.writes.entries) {
      written.add(path);
      File('$root/$path').writeAsStringSync(text);
    }
    // The table is in both languages, so the translation is current again.
    stampTranslation(Directory('$root/docs/guide'), 'id/releases.md');
  } on Object catch (e) {
    errors.writeln(
      'The release stopped half-way: $e\n'
      'Files were modified (${written.length} of ${plan.writes.length})'
      '${plan.fragments.isEmpty ? '' : ' and the fragments removed'}. '
      'Restore the tree with:\n'
      '${plan.fragments.isEmpty ? '' : '  $restoreFragments\n'}'
      '  git restore -- ${written.join(' ')}',
    );
    return 1;
  }

  (out ?? stdout).writeln('''
Prepared ${plan.current} → $version in ${plan.members.length} packages.
Next:
  dart run tool/docs/generate.dart        # refresh the generated docs
  git diff                                # review, then:
  git commit -am "Release $version"
  git push                                # wait for CI, then:
  git tag -a v$version -m "Daravel $version" && git push origin v$version''');
  return 0;
}

List<String> _workspace(String pubspec) {
  final lines = pubspec.split('\n');
  final start = lines.indexOf('workspace:');
  if (start == -1) {
    return const [];
  }
  return [
    for (final line
        in lines.skip(start + 1).takeWhile((l) => l.startsWith('  - ')))
      line.substring(4).trim(),
  ];
}
