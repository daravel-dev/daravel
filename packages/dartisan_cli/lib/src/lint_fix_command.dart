import 'dart:io';

import 'package:daravel_lints/daravel_lints.dart';
import 'package:path/path.dart' as p;

import 'project_commands.dart' show dartExecutable;

/// One file `dartisan lint --fix` changes: its project-relative [path],
/// the text before and after, and the fixes applied.
typedef LintFileFix = ({
  String path,
  String before,
  String after,
  List<String> messages,
});

/// The fixes `dartisan lint --fix` would make in the project at [root]:
/// [fixSource] over every Dart file `dartisan lint` reads
/// ([lintDirectories]), with [rules].
List<LintFileFix> planLintFixes(String root, List<LintRule> rules) {
  final changes = <LintFileFix>[];
  for (final directory in lintDirectories) {
    final dir = Directory(p.join(root, directory));
    if (!dir.existsSync()) {
      continue;
    }
    final files =
        dir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    for (final file in files) {
      final before = file.readAsStringSync();
      final path = p.relative(file.path, from: root).replaceAll(r'\', '/');
      final fixed = fixSource(before, path, rules: rules);
      if (fixed != null) {
        changes.add((
          path: path,
          before: before,
          after: fixed.source,
          messages: fixed.messages,
        ));
      }
    }
  }
  return changes;
}

/// The changed lines between [before] and [after], as `dartisan lint
/// --fix --dry-run` prints them: `--- path`/`+++ path`, then each run of
/// changed lines with its line number (`@@ 12 @@`), `-` before and `+`
/// after. Lines are matched with a longest common subsequence over the
/// part between the common start and end.
String lintFixDiff(String path, String before, String after) {
  final a = before.split('\n');
  final b = after.split('\n');
  var start = 0;
  while (start < a.length && start < b.length && a[start] == b[start]) {
    start++;
  }
  var endA = a.length;
  var endB = b.length;
  while (endA > start && endB > start && a[endA - 1] == b[endB - 1]) {
    endA--;
    endB--;
  }
  final x = a.sublist(start, endA);
  final y = b.sublist(start, endB);
  // lcs[i][j]: the common subsequence of x[i..] and y[j..].
  final lcs = List.generate(
    x.length + 1,
    (_) => List<int>.filled(y.length + 1, 0),
  );
  for (var i = x.length - 1; i >= 0; i--) {
    for (var j = y.length - 1; j >= 0; j--) {
      lcs[i][j] = x[i] == y[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] >= lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }
  final out = StringBuffer('--- $path\n+++ $path\n');
  var i = 0;
  var j = 0;
  var inHunk = false;
  while (i < x.length || j < y.length) {
    if (i < x.length && j < y.length && x[i] == y[j]) {
      i++;
      j++;
      inHunk = false;
      continue;
    }
    if (!inHunk) {
      out.writeln('@@ ${start + i + 1} @@');
      inHunk = true;
    }
    if (i < x.length && (j == y.length || lcs[i + 1][j] >= lcs[i][j + 1])) {
      out.writeln('-${x[i++]}');
    } else {
      out.writeln('+${y[j++]}');
    }
  }
  return out.toString();
}

/// The project files among [paths] that git sees as changed (modified,
/// staged or untracked): `--fix` leaves them alone without `--force`, so
/// `git checkout` can always undo it. `null` when [root] is not in a git
/// work tree, or git is missing.
Future<List<String>?> uncommittedFiles(String root, List<String> paths) async {
  final ProcessResult result;
  try {
    result = await Process.run('git', [
      'status',
      '--porcelain',
      '--untracked-files=all',
      '--',
      ...paths,
    ], workingDirectory: root);
  } on ProcessException {
    return null;
  }
  if (result.exitCode != 0) {
    return null;
  }
  return [
    for (final line in (result.stdout as String).split('\n'))
      if (line.trim().isNotEmpty) line.substring(3).trim(),
  ];
}

/// The number of errors `dart analyze` reports in each of [paths]
/// (project-relative) of the project at [root].
Future<Map<String, int>> analyzeErrors(String root, List<String> paths) async {
  final result = await Process.run(dartExecutable(), [
    'analyze',
    '--format=machine',
    ...paths,
  ], workingDirectory: root);
  final counts = {for (final path in paths) path: 0};
  // SEVERITY|TYPE|CODE|FILE|LINE|COLUMN|LENGTH|MESSAGE
  for (final line in '${result.stdout}\n${result.stderr}'.split('\n')) {
    final fields = line.split('|');
    if (fields.length < 8 || fields[0] != 'ERROR') {
      continue;
    }
    final file = p.isAbsolute(fields[3])
        ? p.relative(fields[3], from: root)
        : fields[3];
    final path = file.replaceAll(r'\', '/');
    if (counts.containsKey(path)) {
      counts[path] = counts[path]! + 1;
    }
  }
  return counts;
}
