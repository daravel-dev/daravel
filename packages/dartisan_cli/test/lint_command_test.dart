import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:daravel_lints/daravel_lints.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `dartisan lint` prints each finding as `dart analyze` does, keeps
/// `--json` for tools and fails when there are findings.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dartisan_lint');
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');
    Directory(p.join(root.path, 'bootstrap')).createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Future<(int, String)> lint(List<String> args) async {
    // ignore: close_sinks (stdout of the zone, never opened)
    final out = _Capture();
    final code = await IOOverrides.runZoned(
      () => DartisanRunner(
        () => Application.configure(basePath: root.path).create(),
      ).execute(['lint', ...args]),
      getCurrentDirectory: () => root,
      stdout: () => out,
    );
    return (code, out.buffer.toString());
  }

  void writeAssets() {
    File(p.join(root.path, 'lib', 'app', 'web', 'assets.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync('''
final class Assets {
  static Assets? _instance;
}
''');
  }

  test('a clean project: no findings, exit 0', () async {
    final (code, output) = await lint([]);
    expect(code, 0);
    expect(output.trim(), 'No issues found.');
  });

  test('each finding with its location, message and rule', () async {
    writeAssets();
    final (code, output) = await lint([]);
    expect(code, 1);
    final lines = const LineSplitter().convert(output);
    expect(
      lines.first,
      matches(
        RegExp(
          r'^  info - lib/app/web/assets\.dart:2:\d+ - Static field '
          r'`_instance` .+ - no_mutable_static_in_app$',
        ),
      ),
    );
    expect(lines.last, '1 issue found.');
  });

  test('--json is unchanged', () async {
    writeAssets();
    final (code, output) = await lint(['--json']);
    expect(code, 1);
    final issues = jsonDecode(output) as List<Object?>;
    expect(issues, hasLength(1));
    expect((issues.single! as Map<String, Object?>).keys, [
      'rule',
      'message',
      'path',
      'line',
      'column',
    ]);
    expect(
      (issues.single! as Map<String, Object?>)['rule'],
      'no_mutable_static_in_app',
    );
  });

  test('formatLintIssue', () {
    expect(
      formatLintIssue(
        const LintIssue(
          rule: 'r',
          message: 'm',
          path: r'lib\app\x.dart',
          line: 14,
          column: 18,
        ),
      ),
      '  info - lib/app/x.dart:14:18 - m - r',
    );
  });
}

/// Collects what a command prints.
final class _Capture implements Stdout {
  final StringBuffer buffer = StringBuffer();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
