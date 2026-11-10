// Checks that `dartLiteral` (tool/docs/guide_pages.dart) says every text
// exactly, as Dart itself reads it: the edge cases are written into a
// program, run, and what it prints compared with the texts.
//
//   dart run tool/docs/guide_pages_selftest.dart
import 'dart:convert';
import 'dart:io';

import 'guide_pages.dart';

const List<String> cases = [
  '',
  'plain',
  'one line\n',
  '\nstarts with a blank line',
  '   \nstarts with blanks',
  '\t\nstarts with a tab line',
  '\\\nstarts with a backslash line',
  ' \\ \nblanks and a backslash',
  "ends with a quote'",
  "ends with two quotes''",
  "''' at the start",
  "in the ''' middle",
  "ends with three'''",
  "four '''' quotes",
  "five ''''' quotes",
  r'a $dollar and ${braces}',
  r'back\slash \n not a newline \\',
  'windows\r\nline ends\r\n',
  'a lone \r carriage return',
  'tab\tand control \u0001 char',
  'unicode: é ü ✓ 日本 🙂',
  "mixed '''\n\n  \n'''\n'",
  '```dart\nfinal s = r"""x""";\n```\n',
];

void main() {
  final dir = Directory.systemTemp.createTempSync('guide_pages_selftest_');
  try {
    final program = StringBuffer("import 'dart:convert';\n\nconst cases = [\n");
    for (final text in cases) {
      program.writeln('  ${dartLiteral(text)},');
    }
    program
      ..writeln('];')
      ..writeln()
      ..writeln('void main() => print(jsonEncode(cases));');
    final file = File('${dir.path}${Platform.pathSeparator}cases.dart')
      ..writeAsStringSync(program.toString());
    final run = Process.runSync(Platform.resolvedExecutable, [
      'run',
      file.path,
    ], stdoutEncoding: utf8);
    if (run.exitCode != 0) {
      stderr.writeln('The program does not compile:\n${run.stderr}');
      exitCode = 1;
      return;
    }
    final read = (jsonDecode(run.stdout as String) as List).cast<String>();
    var failures = 0;
    for (var i = 0; i < cases.length; i++) {
      final ok = i < read.length && read[i] == cases[i];
      if (!ok) {
        failures++;
        stderr.writeln(
          'FAIL ${jsonEncode(cases[i])}: read ${i < read.length ? jsonEncode(read[i]) : 'nothing'}'
          ' from ${dartLiteral(cases[i])}',
        );
      }
    }
    // Names: distinct files and constants for distinct pages.
    const pages = ['getting-started.md', 'id/getting-started.md', 'parity.md'];
    final files = {for (final p in pages) guidePageFile(p)};
    final constants = {for (final p in pages) guidePageConstant(p)};
    if (files.length != pages.length || constants.length != pages.length) {
      stderr.writeln('FAIL names: $files $constants');
      failures++;
    }
    if (guidePageFile('id/getting-started.md') != 'id_getting_started.g.dart' ||
        guidePageConstant('id/getting-started.md') != 'pageIdGettingStarted') {
      stderr.writeln('FAIL names of id/getting-started.md');
      failures++;
    }
    stdout.writeln(
      '${cases.length} texts and the names checked, $failures failure(s).',
    );
    if (failures > 0) {
      exitCode = 1;
    }
  } finally {
    dir.deleteSync(recursive: true);
  }
}
