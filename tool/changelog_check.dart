import 'dart:io';

import 'changelog.dart';

/// Checks CHANGELOG.md for a change (KEP-04.3):
///
/// - `## Unreleased` is there with `### Added`, `### Changed` (and its
///   upgrade label) and `### Fixed`, and a release can place every line
///   under it: no other header, no `* ` bullet, no text that is not part
///   of a `- ` note (`validateReleaseInput`, the check that `--preview`
///   and `tool/release.dart` make as well);
/// - every fragment in `changelog.d/` is valid (its name, its sections,
///   notes only);
/// - a change that adds an `export` to a package's top-level library
///   (`packages/<pkg>/lib/*.dart`) also adds an upgrade note, under the
///   upgrade label or under `### Upgrade notes` of a fragment, since a new
///   public name can break an application that declares the same name.
///
/// ```bash
/// dart run tool/changelog_check.dart               # against origin/main
/// dart run tool/changelog_check.dart --base=HEAD^1 # CI: the PR merge commit
/// ```
///
/// Exits 1 with the problems, 0 when there are none.
Future<void> main(List<String> args) async {
  final given = args
      .where((a) => a.startsWith('--base='))
      .map((a) => a.substring(7))
      .firstOrNull;
  exitCode = await checkChangelog('.', given, stdout, stderr);
}

/// The check of the repository under [root] against commit [base] (the
/// merge base with `origin/main` when null): what is in order to [out],
/// the problems to [err]. The exit code: 1 with problems, 2 when git
/// fails.
Future<int> checkChangelog(
  String root,
  String? base,
  StringSink out,
  StringSink err,
) async {
  try {
    final problems = <String>[];
    final summary = await _check(
      root,
      base ?? (await _git(root, ['merge-base', 'origin/main', 'HEAD'])).trim(),
      problems,
    );
    if (problems.isEmpty) {
      out.writeln(summary);
      return 0;
    }
    for (final problem in problems) {
      err.writeln(problem);
    }
    return 1;
  } on _GitFailure catch (e) {
    err.writeln(e.message);
    return 2;
  }
}

/// Adds what is wrong to [problems]; what to say when nothing is.
Future<String> _check(String root, String base, List<String> problems) async {
  // What `--preview` and tool/release.dart refuse, this refuses too.
  final input = readReleaseInput(root: root);
  final head = input.changelog;
  problems.addAll(input.problems);
  final headFragments = input.fragments;

  final diff = await _git(root, [
    'diff',
    '--unified=0',
    base,
    '--',
    'packages/*/lib/*.dart',
  ]);
  // Only a package's top-level libraries are its public API.
  final topLevel = RegExp(r'^packages/[^/]+/lib/[^/]+\.dart:');
  final exports = [
    for (final e in addedExportsIn(diff))
      if (topLevel.hasMatch(e)) e,
  ];
  if (exports.isNotEmpty) {
    final before = await _git(root, ['show', '$base:CHANGELOG.md']);
    // A release commit (tool/release.dart) moves the notes under the new
    // version and leaves `## Unreleased` empty, above the new version's
    // header: the section ends at the version the workspace is at now.
    final version = input.currentVersion;
    final baseVersion = daravelVersionIn(
      await _git(root, ['show', '$base:$versionFile']),
    );
    final released =
        version != null &&
        version != baseVersion &&
        !hasNotes(unreleasedBody(head, currentVersion: version) ?? '');
    problems.addAll(
      upgradeNoteProblems(
        baseChangelog: before,
        headChangelog: head,
        addedExports: exports,
        releasedVersion: released ? version : null,
        baseFragments: await _fragmentsAt(root, base),
        headFragments: headFragments,
        baseVersion: baseVersion,
        headVersion: version,
      ),
    );
  }
  return 'CHANGELOG.md is in order'
      '${headFragments.isEmpty ? '' : ', ${headFragments.length} fragment(s)'}'
      '${exports.isEmpty ? '' : ' (${exports.length} new export line(s), upgrade note present)'}.';
}

/// The valid fragments of `changelog.d/` at commit [ref] (none before the
/// directory existed).
Future<List<Fragment>> _fragmentsAt(String root, String ref) async {
  final listing = await Process.run('git', [
    'ls-tree',
    '--name-only',
    ref,
    '$fragmentsDirectory/',
  ], workingDirectory: root);
  if (listing.exitCode != 0) {
    return const [];
  }
  final fragments = <Fragment>[];
  for (final path in (listing.stdout as String).split('\n')) {
    final name = path.split('/').last;
    if (!name.endsWith('.md') || name == 'README.md') {
      continue;
    }
    final text = await _git(root, ['show', '$ref:$path']);
    if (fragmentProblems(name, text).isEmpty) {
      fragments.add(parseFragment(name.substring(0, name.length - 3), text));
    }
  }
  return fragments;
}

/// A git command that failed: the check cannot tell (exit code 2).
final class _GitFailure implements Exception {
  _GitFailure(this.message);

  final String message;
}

Future<String> _git(String root, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: root);
  if (result.exitCode != 0) {
    throw _GitFailure('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return result.stdout as String;
}
