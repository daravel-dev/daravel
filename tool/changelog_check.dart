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
  final String base =
      given ?? (await _git(['merge-base', 'origin/main', 'HEAD'])).trim();

  // What `--preview` and tool/release.dart refuse, this refuses too.
  final input = readReleaseInput();
  final head = input.changelog;
  final problems = [...input.problems];
  final headFragments = input.fragments;

  final diff = await _git([
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
    final before = await _git(['show', '$base:CHANGELOG.md']);
    // A release commit (tool/release.dart) moves the notes under the new
    // version and leaves `## Unreleased` empty.
    const versionFile = 'packages/daravel/lib/src/foundation/version.dart';
    final version = daravelVersionIn(File(versionFile).readAsStringSync());
    final baseVersion = daravelVersionIn(
      await _git(['show', '$base:$versionFile']),
    );
    final released =
        version != null &&
        version != baseVersion &&
        !hasNotes(unreleasedBody(head) ?? '');
    problems.addAll(
      upgradeNoteProblems(
        baseChangelog: before,
        headChangelog: head,
        addedExports: exports,
        releasedVersion: released ? version : null,
        baseFragments: await _fragmentsAt(base),
        headFragments: headFragments,
      ),
    );
  }

  if (problems.isEmpty) {
    stdout.writeln(
      'CHANGELOG.md is in order'
      '${headFragments.isEmpty ? '' : ', ${headFragments.length} fragment(s)'}'
      '${exports.isEmpty ? '' : ' (${exports.length} new export line(s), upgrade note present)'}.',
    );
    return;
  }
  for (final problem in problems) {
    stderr.writeln(problem);
  }
  exitCode = 1;
}

/// The valid fragments of `changelog.d/` at commit [ref] (none before the
/// directory existed).
Future<List<Fragment>> _fragmentsAt(String ref) async {
  final listing = await Process.run('git', [
    'ls-tree',
    '--name-only',
    ref,
    '$fragmentsDirectory/',
  ]);
  if (listing.exitCode != 0) {
    return const [];
  }
  final fragments = <Fragment>[];
  for (final path in (listing.stdout as String).split('\n')) {
    final name = path.split('/').last;
    if (!name.endsWith('.md') || name == 'README.md') {
      continue;
    }
    final text = await _git(['show', '$ref:$path']);
    if (fragmentProblems(name, text).isEmpty) {
      fragments.add(parseFragment(name.substring(0, name.length - 3), text));
    }
  }
  return fragments;
}

Future<String> _git(List<String> args) async {
  final result = await Process.run('git', args);
  if (result.exitCode != 0) {
    stderr.writeln('git ${args.join(' ')} failed: ${result.stderr}');
    exit(2);
  }
  return result.stdout as String;
}
