import 'dart:io';
import 'dart:typed_data';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
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
/// after. Lines are matched with Myers' shortest edit script, in time
/// O((N + M) · D) and memory O(D²) for D changed lines, so a long file
/// with a few fixes far apart costs little (a table of N × M cells did
/// not: 20 000 lines took 3.9 GB).
String lintFixDiff(String path, String before, String after) {
  final a = before.split('\n');
  final b = after.split('\n');
  final out = StringBuffer('--- $path\n+++ $path\n');
  var inHunk = false;
  var line = 0;
  for (final (op, text) in lineEdits(a, b)) {
    if (op == ' ') {
      line++;
      inHunk = false;
      continue;
    }
    if (!inHunk) {
      out.writeln('@@ ${line + 1} @@');
      inHunk = true;
    }
    out.writeln('$op$text');
    if (op == '-') {
      line++;
    }
  }
  return out.toString();
}

/// Myers' diff of [a] and [b] (the lines [lintFixDiff] prints): each line kept (`' '`), removed (`'-'`)
/// or added (`'+'`), removals before additions within a change.
List<(String, String)> lineEdits(List<String> a, List<String> b) {
  final n = a.length;
  final m = b.length;
  final max = n + m;
  // v[k + off]: the furthest x on diagonal k. Before each step d, the
  // diagonals -(d + 1)..d + 1 of v are kept (all the walk back reads), so
  // the trace holds O(D²) numbers, not D copies of v.
  final off = max + 1;
  final v = Int32List(2 * max + 4);
  final trace = <Int32List>[];
  int at(int d, int k) => trace[d][k + d + 1];
  search:
  for (var d = 0; d <= max; d++) {
    trace.add(Int32List.sublistView(v, off - d - 1, off + d + 2).sublist(0));
    for (var k = -d; k <= d; k += 2) {
      final down = k == -d || (k != d && v[k - 1 + off] < v[k + 1 + off]);
      var x = down ? v[k + 1 + off] : v[k - 1 + off] + 1;
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[k + off] = x;
      if (x >= n && y >= m) {
        break search;
      }
    }
  }
  final edits = <(String, String)>[];
  var x = n;
  var y = m;
  for (var d = trace.length - 1; d >= 0; d--) {
    final k = x - y;
    final down = k == -d || (k != d && at(d, k - 1) < at(d, k + 1));
    final prevK = down ? k + 1 : k - 1;
    final prevX = at(d, prevK);
    final prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      edits.add((' ', a[--x]));
      y--;
    }
    if (d > 0) {
      if (down) {
        edits.add(('+', b[--y]));
      } else {
        edits.add(('-', a[--x]));
      }
    }
  }
  while (x > 0 && y > 0) {
    edits.add((' ', a[--x]));
    y--;
  }
  final ordered = edits.reversed.toList();
  // Within each run of changes, removals first (`-` then `+`).
  final result = <(String, String)>[];
  var run = <(String, String)>[];
  void flush() {
    result
      ..addAll(run.where((e) => e.$1 == '-'))
      ..addAll(run.where((e) => e.$1 == '+'));
    run = [];
  }

  for (final edit in ordered) {
    if (edit.$1 == ' ') {
      flush();
      result.add(edit);
    } else {
      run.add(edit);
    }
  }
  flush();
  return result;
}

/// Writes [content] to [path] so the file is never half written: into a
/// file next to it first, then renamed over it (a rename on one volume
/// replaces the file at once). A process killed in between leaves the old
/// file and a stray `*.lint-fix.tmp`, never a cut-off one. On Linux and
/// macOS the new file gets the permissions of the old one (a script in
/// `bin/` stays executable); Windows has no such bits.
void writeFileAtomically(String path, String content) {
  final temp = File('$path.lint-fix.tmp')
    ..writeAsStringSync(content, flush: true);
  final target = File(path);
  if (!Platform.isWindows && target.existsSync()) {
    final permissions = target.statSync().mode & 0xFFF;
    final chmod = Process.runSync('chmod', [
      permissions.toRadixString(8),
      temp.path,
    ]);
    if (chmod.exitCode != 0) {
      temp.deleteSync();
      throw FileSystemException(
        'could not keep the permissions: ${chmod.stderr}'.trim(),
        path,
      );
    }
  }
  temp.renameSync(path);
}

/// Deletes the `*.lint-fix.tmp` files a killed `lint --fix` left in the
/// folders it writes ([lintDirectories]) of the project at [root], and
/// returns their project-relative paths ([dryRun]: only lists them). The
/// file each sat next to is
/// whole (the old text or the fixed one), so the temporary copy is safe to
/// drop.
List<String> removeStaleLintFixFiles(String root, {bool dryRun = false}) {
  final removed = <String>[];
  for (final directory in lintDirectories) {
    final dir = Directory(p.join(root, directory));
    if (!dir.existsSync()) {
      continue;
    }
    for (final file in dir.listSync(recursive: true).whereType<File>()) {
      if (file.path.endsWith('.lint-fix.tmp')) {
        if (!dryRun) {
          file.deleteSync();
        }
        removed.add(p.relative(file.path, from: root).replaceAll(r'\', '/'));
      }
    }
  }
  return removed..sort();
}

/// The project files among [paths] that `git checkout` could not bring
/// back: changed (modified, staged or untracked), or ignored by git
/// (`.gitignore`). `--fix` leaves them alone without `--force`. Each comes
/// with why (`uncommitted` or `ignored by git`). `null` when [root] is not
/// in a git work tree, or git is missing.
Future<List<(String, String)>?> uncommittedFiles(
  String root,
  List<String> paths,
) async {
  final ProcessResult result;
  try {
    result = await Process.run('git', [
      'status',
      '--porcelain',
      '--untracked-files=all',
      '--ignored',
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
      if (line.trim().isNotEmpty)
        (
          line.substring(3).trim(),
          line.startsWith('!!') ? 'ignored by git' : 'uncommitted',
        ),
  ];
}

/// The files of the library [path] (project-relative, in the project at
/// [root]) belongs to: the library file and its `part`s, found from
/// either side (`part 'x.dart';`, `part of 'lib.dart';`). A file outside
/// any such library is its own library. `part of` a library name (no URI)
/// cannot be followed and leaves the file on its own.
Set<String> libraryFiles(String root, String path) {
  String? read(String relative) {
    final file = File(p.join(root, relative));
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  String resolve(String from, String uri) =>
      p.normalize(p.join(p.dirname(from), uri)).replaceAll(r'\', '/');

  CompilationUnit? parse(String relative) => switch (read(relative)) {
    final String source => parseString(
      content: source,
      throwIfDiagnostics: false,
    ).unit,
    null => null,
  };

  var library = path;
  final ownUnit = parse(path);
  for (final directive in ownUnit?.directives ?? const <Directive>[]) {
    if (directive is PartOfDirective && directive.uri?.stringValue != null) {
      library = resolve(path, directive.uri!.stringValue!);
    }
  }
  final libraryUnit = library == path ? ownUnit : parse(library);
  return {
    path,
    library,
    for (final directive in libraryUnit?.directives ?? const <Directive>[])
      if (directive is PartDirective && directive.uri.stringValue != null)
        resolve(library, directive.uri.stringValue!),
  };
}

/// The fields of one line of `dart analyze --format=machine`, unescaped:
/// the format writes a `|` inside a field as `\|` and a `\` as `\\`
/// (Windows paths come out as `C:\\Users\\...`).
List<String> machineFields(String line) {
  final fields = <String>[];
  final field = StringBuffer();
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (c == r'\' && i + 1 < line.length) {
      field.write(line[++i]);
    } else if (c == '|') {
      fields.add(field.toString());
      field.clear();
    } else {
      field.write(c);
    }
  }
  fields.add(field.toString());
  return fields;
}

/// The number of errors `dart analyze` reports in each of [paths]
/// (project-relative) of the project at [root], or `null` when it did not
/// analyze them (it could not start, or ended without a result: an exit
/// code other than 0 and no finding in its output), which is not the same
/// as no errors. [executable] replaces the Dart SDK's `dart` (tests).
Future<Map<String, int>?> analyzeErrors(
  String root,
  List<String> paths, {
  String? executable,
}) async {
  final ProcessResult result;
  try {
    result = await Process.run(executable ?? dartExecutable(), [
      'analyze',
      '--format=machine',
      ...paths,
    ], workingDirectory: root);
  } on ProcessException {
    return null;
  }
  final counts = {for (final path in paths) path: 0};
  var findings = 0;
  // SEVERITY|TYPE|CODE|FILE|LINE|COLUMN|LENGTH|MESSAGE
  for (final line in '${result.stdout}\n${result.stderr}'.split('\n')) {
    final fields = machineFields(line);
    if (fields.length < 8 ||
        !const {'ERROR', 'WARNING', 'INFO'}.contains(fields[0])) {
      continue;
    }
    findings++;
    if (fields[0] != 'ERROR') {
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
  return result.exitCode == 0 || findings > 0 ? counts : null;
}
