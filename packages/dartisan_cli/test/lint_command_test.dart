import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
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

    test('string_column_name reads the project models once enabled', () async {
      File(p.join(root.path, 'lib', 'app', 'models', 'user.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('''
final class User extends Model {
  static const cols = (email: ModelColumn<User, String>('email'));
}
''');
      File(p.join(root.path, 'lib', 'app', 'query.dart')).writeAsStringSync(
        "Future<void> f() => User.query().where('email', 1).get();\n",
      );
      expect(await lint([]), (0, 'No issues found.\n'));
      options('daravel_lints:\n  diagnostics:\n    string_column_name: true\n');
      final (code, output) = await lint([]);
      expect(code, 1);
      expect(output, contains('Use User.cols.email'));
      expect(
        const LineSplitter().convert(output).last,
        '1 issue found (opt-in rules on: string_column_name).',
      );
      // --enable works for it as for the other opt-in rules.
      options('');
      expect((await lint(['--enable=string_column_name'])).$1, 1);
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

  group('--fix (W9.8 PR 3)', () {
    // A controller whose rules are strings; the project resolves
    // package:daravel (a package config pointing at this workspace), so
    // `dart analyze` sees what the fix really does.
    const controller = '''
import 'package:daravel/daravel.dart';

Future<void> store(Request request) =>
    request.validate({'email': 'required|email', 'name': 'required'});
''';
    late File file;

    setUp(() {
      File(p.join(root.path, 'analysis_options.yaml')).writeAsStringSync(
        'daravel_lints:\n  diagnostics:\n    string_validation_rule: true\n',
      );
      file = File(p.join(root.path, 'lib', 'app', 'controller.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync(controller);
      _workspacePackageConfig(root.path);
    });

    Future<void> git(List<String> args) async {
      final result = await Process.run('git', [
        '-c',
        'user.name=test',
        '-c',
        'user.email=test@example.invalid',
        ...args,
      ], workingDirectory: root.path);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }

    Future<void> commitAll() async {
      await git(['init', '-q']);
      await git(['add', '-A']);
      await git(['commit', '-q', '-m', 'start']);
    }

    test('--dry-run prints the change and writes nothing', () async {
      final (code, output) = await lint(['--fix', '--dry-run']);
      expect(code, 1, reason: 'the findings are still there');
      expect(
        output,
        allOf([
          contains('--- lib/app/controller.dart'),
          contains("-    request.validate({'email': 'required|email', "),
          contains('+    request.validate({'),
          contains('Rules.required().email()'),
          contains('Would fix 2 findings in 1 file.'),
        ]),
      );
      expect(file.readAsStringSync(), controller);
    });

    test(
      'refuses outside git and on uncommitted files, unless --force',
      () async {
        expect((await lint(['--fix'])).$1, 1);
        expect(errors.toString(), contains('not a git work tree'));
        expect(file.readAsStringSync(), controller);
        await commitAll();
        file.writeAsStringSync('$controller// edited\n');
        expect((await lint(['--fix'])).$1, 1);
        expect(errors.toString(), contains('lib/app/controller.dart'));
        expect(file.readAsStringSync(), '$controller// edited\n');
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test('fixes, formats, and the project lints clean', () async {
      await commitAll();
      final (code, output) = await lint(['--fix']);
      expect(code, 0, reason: output);
      expect(output, contains('Fixed 2 findings in 1 file.'));
      expect(output, contains('No issues found'));
      final fixed = file.readAsStringSync();
      expect(fixed, contains("'email': Rules.required().email(),"));
      expect(fixed, contains("'name': Rules.required(),"));
      // dart format ran on it: one entry per line once it is too long.
      expect(fixed, contains('request.validate({\n'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a file the fix would break is left as it was', () async {
      // The rule cannot see that this validate takes strings only (the
      // limit fixFor documents): the fix does not compile, so it is undone.
      const strings = '''
import 'package:daravel/daravel.dart';

final class Form {
  Future<void> validate(Map<String, String> rules) async {}
}

Future<void> store(Form form) => form.validate({'email': 'required'});
''';
      file.writeAsStringSync(strings);
      await commitAll();
      final (code, output) = await lint(['--fix', '--force']);
      expect(code, 1, reason: 'the finding stays');
      expect(errors.toString(), contains('did not compile after the fix'));
      expect(output, contains('Fixed 0 findings in 0 files; 1 file left'));
      expect(file.readAsStringSync(), strings);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('an error the file already had does not undo the fix', () async {
      file.writeAsStringSync("$controller\nconst int broken = 'not an int';\n");
      await commitAll();
      final (_, output) = await lint(['--fix']);
      expect(errors.toString(), isNot(contains('did not compile')));
      expect(output, contains('Fixed 2 findings in 1 file.'));
      expect(file.readAsStringSync(), contains('Rules.required().email()'));
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
      'a temporary file a killed run left is removed on the next run',
      () async {
        final stale = File('${file.path}.lint-fix.tmp')
          ..writeAsStringSync('half');
        final (_, dry) = await lint(['--fix', '--dry-run']);
        expect(
          dry,
          contains(
            'Would remove lib/app/controller.dart.lint-fix.tmp, left by a '
            'lint --fix that did not finish.',
          ),
        );
        expect(stale.existsSync(), isTrue, reason: '--dry-run writes nothing');
        await commitAll();
        final (_, output) = await lint(['--fix', '--force']);
        expect(
          output,
          contains('Removed lib/app/controller.dart.lint-fix.tmp'),
        );
        expect(stale.existsSync(), isFalse);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    /// `lint` with [analyzer] as the `dart` that `--fix` analyzes with.
    Future<int> lintWith(String analyzer, List<String> args) async {
      // ignore: close_sinks (stdout of the zone, never opened)
      final out = _Capture();
      // ignore: close_sinks (stderr of the zone, never opened)
      final err = _Capture();
      errors = err.buffer;
      final runner = CommandRunner<int>('dartisan', 'test')
        ..addCommand(LintCommand(analyzer: analyzer));
      return await IOOverrides.runZoned<Future<int?>>(
            () => runner.run(['lint', ...args]),
            getCurrentDirectory: () => root,
            stdout: () => out,
            stderr: () => err,
          ) ??
          0;
    }

    test('dart analyze that does not run puts every file back', () async {
      await commitAll();
      for (final analyzer in [
        p.join(root.path, 'no-such-dart'),
        // Runs, exits 1, reports nothing: no verdict either.
        'git',
      ]) {
        expect(await lintWith(analyzer, ['--fix']), 1, reason: analyzer);
        expect(
          errors.toString(),
          contains(
            'dart analyze did not run, so no fix could be checked; every '
            'file is left as it was.',
          ),
          reason: analyzer,
        );
        expect(file.readAsStringSync(), controller, reason: analyzer);
      }
      // The missing executable could not format either, and says so.
      await lintWith(p.join(root.path, 'no-such-dart'), ['--fix']);
      expect(
        errors.toString(),
        contains('lint --fix: dart format did not run ('),
      );
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
      '--fix --json and --fix --dry-run --json: stdout is the JSON',
      () async {
        await commitAll();
        for (final args in [
          ['--fix', '--dry-run', '--json'],
          ['--fix', '--json'],
        ]) {
          final (_, output) = await lint(args);
          expect(
            () => jsonDecode(output) as List<Object?>,
            returnsNormally,
            reason: '$args: $output',
          );
          expect(errors.toString(), contains('fix'), reason: '$args');
        }
        // After the real fix nothing is left: an empty list.
        expect(jsonDecode((await lint(['--json'])).$2), isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test('a part not generated yet is not analyzed', () async {
      final dir = p.join(root.path, 'lib', 'app');
      File(p.join(dir, 'user.dart'))
          .writeAsStringSync("part 'user.g.dart';\n\nclass User {}\n");
      expect(libraryFiles(root.path, 'lib/app/user.dart'), {
        'lib/app/user.dart',
      });
    });

    test('git status -z: a non-ASCII path comes back as it is', () async {
      await commitAll();
      final cafe = File(p.join(root.path, 'lib', 'app', 'café.dart'))
        ..writeAsStringSync('// new\n');
      expect(await uncommittedFiles(root.path, ['lib/app/café.dart']), [
        ('lib/app/café.dart', 'uncommitted'),
      ]);
      cafe.deleteSync();
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a write that fails puts back the files already written', () async {
      // Two files; the second (in path order) cannot be replaced.
      final first = File(p.join(root.path, 'lib', 'app', 'a_first.dart'))
        ..writeAsStringSync(controller);
      await commitAll();
      final locked = Platform.isWindows ? file.path : file.parent.path;
      await Process.run(Platform.isWindows ? 'attrib' : 'chmod', [
        ...Platform.isWindows ? ['+R'] : ['555'],
        locked,
      ]);
      addTearDown(
        () => Process.run(Platform.isWindows ? 'attrib' : 'chmod', [
          ...Platform.isWindows ? ['-R'] : ['755'],
          locked,
        ]),
      );
      final (code, _) = await lint(['--fix']);
      expect(code, 1);
      expect(
        errors.toString(),
        allOf([
          contains('lint --fix: could not write'),
          contains('every file is left as it was.'),
        ]),
      );
      expect(first.readAsStringSync(), controller, reason: 'put back');
      expect(file.readAsStringSync(), controller);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test(
      'a fix that breaks an unchanged part of its library is undone',
      () async {
        // The library imports its own Request, which only the part uses. The
        // fix adds package:daravel (which exports a Request too) to the
        // library, and the part, sharing its imports, no longer compiles.
        final dir = p.join(root.path, 'lib', 'app');
        File(p.join(dir, 'request.dart'))
            .writeAsStringSync('class Request {}\n');
        const library = '''
import 'request.dart';

part 'forms_part.dart';

Future<void> store(dynamic form) => form.validate({'email': 'required'});
''';
        final forms = File(p.join(dir, 'forms.dart'))
          ..writeAsStringSync(library);
        File(p.join(dir, 'forms_part.dart')).writeAsStringSync(
          "part of 'forms.dart';\n\nRequest make() => Request();\n",
        );
        file.deleteSync();
        await commitAll();
        expect(libraryFiles(root.path, 'lib/app/forms_part.dart'), {
          'lib/app/forms_part.dart',
          'lib/app/forms.dart',
        });
        final (_, output) = await lint(['--fix']);
        expect(
          errors.toString(),
          contains('lib/app/forms.dart did not compile'),
        );
        expect(output, contains('1 file left as it was'));
        expect(forms.readAsStringSync(), library);
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test('a file git ignores is refused like an uncommitted one', () async {
      File(p.join(root.path, '.gitignore'))
          .writeAsStringSync('lib/app/controller.dart\n');
      await commitAll();
      expect((await lint(['--fix'])).$1, 1);
      expect(
        errors.toString(),
        contains('lib/app/controller.dart (ignored by git)'),
      );
      expect(file.readAsStringSync(), controller);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a script keeps its permissions', () async {
      final script = File(p.join(root.path, 'bin', 'tool.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('old\n');
      await Process.run('chmod', ['754', script.path]);
      writeFileAtomically(script.path, 'new\n');
      expect(script.readAsStringSync(), 'new\n');
      expect(script.statSync().mode & 0xFFF, 0x1EC); // 0754
    }, skip: Platform.isWindows ? 'no permission bits on Windows' : false);

    test('a file is replaced whole, with no temporary file left', () {
      writeFileAtomically(file.path, 'replaced\n');
      expect(file.readAsStringSync(), 'replaced\n');
      expect(File('${file.path}.lint-fix.tmp').existsSync(), isFalse);
    });

    test('--dry-run and --force without --fix are refused', () async {
      expect((await lint(['--dry-run'])).$1, 64);
      expect((await lint(['--force'])).$1, 64);
    });
  });
}

/// Writes `.dart_tool/package_config.json` into the project at [root]
/// with the packages of this workspace (absolute URIs), so `dart analyze`
/// resolves `package:daravel` there without `pub get`.
void _workspacePackageConfig(String root) {
  final workspace = p.normalize(p.join(Directory.current.path, '..', '..'));
  final source = File(p.join(workspace, '.dart_tool', 'package_config.json'));
  final config = jsonDecode(source.readAsStringSync()) as Map<String, Object?>;
  final base = Uri.directory(p.join(workspace, '.dart_tool'));
  final packages = [
    for (final package
        in (config['packages']! as List<Object?>).cast<Map<String, Object?>>())
      {
        ...package,
        'rootUri': base.resolve(package['rootUri']! as String).toString(),
      },
  ];
  File(p.join(root, '.dart_tool', 'package_config.json'))
    ..createSync(recursive: true)
    ..writeAsStringSync(jsonEncode({...config, 'packages': packages}));
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
