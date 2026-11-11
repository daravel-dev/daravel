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

  var errors = StringBuffer();

  Future<(int, String)> lint(List<String> args) async {
    // ignore: close_sinks (stdout of the zone, never opened)
    final out = _Capture();
    // ignore: close_sinks (stderr of the zone, never opened)
    final err = _Capture();
    errors = err.buffer;
    final code = await IOOverrides.runZoned(
      () => DartisanRunner(
        () => Application.configure(basePath: root.path).create(),
      ).execute(['lint', ...args]),
      getCurrentDirectory: () => root,
      stdout: () => out,
      stderr: () => err,
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

  group('the rules a project enables (analysis_options.yaml)', () {
    void writeSort() {
      File(p.join(root.path, 'lib', 'app', 'sort.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync(
          "void f(String sort) => DB.table('users').orderBy(sort);\n",
        );
    }

    void options(String yaml) =>
        File(p.join(root.path, 'analysis_options.yaml'))
            .writeAsStringSync(yaml);

    test('an opt-in rule stays off without configuration', () async {
      writeSort();
      expect(await lint([]), (0, 'No issues found.\n'));
    });

    test('daravel_lints: diagnostics: turns it on, and the summary says '
        'so', () async {
      writeSort();
      options(
        'daravel_lints:\n  diagnostics:\n    prefer_sql_identifier: true\n',
      );
      final (code, output) = await lint([]);
      expect(code, 1);
      expect(output, contains('- prefer_sql_identifier'));
      expect(
        const LineSplitter().convert(output).last,
        '1 issue found (opt-in rules on: prefer_sql_identifier).',
      );
    });

    test("the plugin's block is the one read when both exist", () async {
      writeSort();
      writeAssets();
      options('''
plugins:
  daravel_lints_plugin:
    diagnostics:
      no_mutable_static_in_app: false
daravel_lints:
  diagnostics:
    prefer_sql_identifier: true
''');
      final (code, output) = await lint([]);
      expect(code, 0);
      expect(
        output.trim(),
        'No issues found (rules off: no_mutable_static_in_app).',
      );
      expect(
        errors.toString(),
        contains('daravel_lints: diagnostics: is ignored'),
      );
    });

    test('--enable and --disable for one run', () async {
      writeSort();
      writeAssets();
      final (code, output) = await lint([
        '--enable=prefer_sql_identifier',
        '--disable=no_mutable_static_in_app,registry_entry_missing',
      ]);
      expect(code, 1);
      expect(
        const LineSplitter().convert(output).last,
        '1 issue found (opt-in rules on: prefer_sql_identifier; rules off: '
        'no_mutable_static_in_app, registry_entry_missing).',
      );
    });

    test('an unknown rule name is an error listing the names', () async {
      options('daravel_lints:\n  diagnostics:\n    no_such_rule: true\n');
      final (code, _) = await lint([]);
      expect(code, 64);
      expect(errors.toString(), contains('no_such_rule'));
      expect(errors.toString(), contains('prefer_sql_identifier'));
      expect((await lint(['--enable=nope'])).$1, 64);
    });

    test('values as the analyzer reads them: severities and a list of '
        'names turn a rule on', () async {
      writeSort();
      for (final yaml in [
        'daravel_lints:\n  diagnostics:\n    prefer_sql_identifier: warning\n',
        'daravel_lints:\n  diagnostics:\n    prefer_sql_identifier: error\n',
        'daravel_lints:\n  diagnostics:\n    - prefer_sql_identifier\n',
      ]) {
        options(yaml);
        final (code, output) = await lint([]);
        expect(code, 1, reason: yaml);
        expect(output, contains('opt-in rules on: prefer_sql_identifier'));
      }
    });

    test('ignore is refused: the analysis server reads it as on', () async {
      options(
        'daravel_lints:\n  diagnostics:\n    prefer_sql_identifier: ignore\n',
      );
      expect((await lint([])).$1, 64);
      expect(errors.toString(), contains('prefer_sql_identifier: false'));
    });

    test('any other value is an error', () async {
      options(
        'daravel_lints:\n  diagnostics:\n    prefer_sql_identifier: maybe\n',
      );
      expect((await lint([])).$1, 64);
      expect(errors.toString(), contains('must be true, false'));
    });

    test('a local include: is not followed, and says so when the file '
        'has no block of its own', () async {
      File(p.join(root.path, 'base.yaml')).writeAsStringSync(
        'daravel_lints:\n  diagnostics:\n    prefer_sql_identifier: true\n',
      );
      options('include: base.yaml\n');
      writeSort();
      expect((await lint([])).$1, 0);
      expect(errors.toString(), contains('include: is not followed'));
      // A package's include (every new project has one) is not worth it.
      options('include: package:lints/recommended.yaml\n');
      expect((await lint([])).$1, 0);
      expect(errors.toString(), isEmpty);
    });

    test(
      "only the project's own file is read, not a workspace root's",
      () async {
        // The project is a package inside a workspace whose root enables the
        // rule: dartisan runs in the package and reads the package's file.
        final package = Directory(p.join(root.path, 'packages', 'app'))
          ..createSync(recursive: true);
        options(
          'daravel_lints:\n  diagnostics:\n    prefer_sql_identifier: true\n',
        );
        File(p.join(package.path, 'pubspec.yaml'))
            .writeAsStringSync('name: app\nresolution: workspace\n');
        File(p.join(package.path, 'lib', 'app', 'sort.dart'))
          ..createSync(recursive: true)
          ..writeAsStringSync(
            "void f(String sort) => DB.table('users').orderBy(sort);\n",
          );
        expect(lintConfig(package.path).enabled, isEmpty);
        expect(lintConfig(root.path).enabled, {'prefer_sql_identifier'});
      },
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
