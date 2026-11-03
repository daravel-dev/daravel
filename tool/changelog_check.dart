import 'dart:io';

import 'changelog.dart';

/// Checks CHANGELOG.md for a change (KEP-04.3):
///
/// - `## Unreleased` is there with `### Added`, `### Changed` (and its
///   upgrade label) and `### Fixed`;
/// - a change that adds an `export` to a package's top-level library
///   (`packages/<pkg>/lib/*.dart`) also adds a line under the upgrade
///   label, since a new public name can break an application that
///   declares the same name.
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

  final head = File('CHANGELOG.md').readAsStringSync();
  final problems = [...unreleasedProblems(head)];

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
    problems.addAll(
      upgradeNoteProblems(
        baseChangelog: before,
        headChangelog: head,
        addedExports: exports,
      ),
    );
  }

  if (problems.isEmpty) {
    stdout.writeln(
      'CHANGELOG.md is in order'
      '${exports.isEmpty ? '' : ' (${exports.length} new export line(s), upgrade note present)'}.',
    );
    return;
  }
  for (final problem in problems) {
    stderr.writeln(problem);
  }
  exitCode = 1;
}

Future<String> _git(List<String> args) async {
  final result = await Process.run('git', args);
  if (result.exitCode != 0) {
    stderr.writeln('git ${args.join(' ')} failed: ${result.stderr}');
    exit(2);
  }
  return result.stdout as String;
}
