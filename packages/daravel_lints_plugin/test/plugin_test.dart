// test_reflective_loader runs the methods named test_..., so they cannot be
// lowerCamelCase.
// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:daravel_lints/daravel_lints.dart';
import 'package:daravel_lints_plugin/daravel_lints_plugin.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

/// The `daravel_lints` rules run by the analysis server (W5.5): the same
/// findings as `dartisan lint`, at the same place, with the same message,
/// the same `daravel-lint-ignore` comments and the same paths skipped.
void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(NoSqlStringInterpolationTest);
  });

  test('defaults are warnings, opt-in rules are lints', () {
    final plugin = DaravelLintsPlugin();
    expect(plugin.warnings, defaultRules);
    expect(plugin.lints, optionalRules);
    expect(plugin.lints.map((r) => r.name), contains('prefer_sql_identifier'));
  });

  test('one diagnostic code per rule, kept for the isolate', () {
    final a = DaravelAnalysisRule(const NoDartMirrors()).diagnosticCode;
    final b = DaravelAnalysisRule(const NoDartMirrors()).diagnosticCode;
    expect(identical(a, b), isTrue);
    expect(a.lowerCaseName, 'no_dart_mirrors');
  });
}

@reflectiveTest
class NoSqlStringInterpolationTest extends AnalysisRuleTest {
  // The lint points at the interpolated SQL literal. Its offset is taken
  // from the text the analyzer sees: `newFile` normalizes line endings to
  // the platform's (`\r\n` on Windows), so a fixed number holds on one
  // platform only.
  static String _query([String comment = '']) =>
      '''
class Db {
  Future<void> whereRaw(String sql) async {}
}

Future<void> f(Db db, String id) => db.whereRaw('id = \$id');$comment
''';

  @override
  void setUp() {
    rule = DaravelAnalysisRule(const NoSqlStringInterpolation());
    super.setUp();
  }

  String get _appFile => '$testPackageRootPath/lib/app/repository.dart';

  Future<void> test_reports_on_the_node_with_the_rule_message() async {
    newFile(_appFile, _query());
    final sql = normalizeSource(_query()).indexOf("'id = ");
    await assertDiagnosticsInFile(_appFile, [
      lint(
        sql,
        "'id = \$id'".length,
        messageContainsAll: [
          'SQL passed to whereRaw is built with interpolation',
        ],
      ),
    ]);
  }

  Future<void> test_daravel_lint_ignore_comment() async {
    newFile(
      _appFile,
      _query(' // daravel-lint-ignore: no_sql_string_interpolation'),
    );
    await assertNoDiagnosticsInFile(_appFile);
  }

  Future<void> test_analyzer_ignore_comment() async {
    newFile(_appFile, _query(' // ignore: no_sql_string_interpolation'));
    await assertNoDiagnosticsInFile(_appFile);
  }

  Future<void> test_skips_lib_src_as_the_cli_does() async {
    final path = '$testPackageRootPath/lib/src/grammar.dart';
    newFile(path, _query());
    await assertNoDiagnosticsInFile(path);
  }

  Future<void> test_placeholders_are_clean() async {
    newFile(_appFile, '''
class Db {
  Future<void> whereRaw(String sql, [List<Object?> bindings = const []]) async {}
}

Future<void> f(Db db, String id) => db.whereRaw('id = ?', [id]);
''');
    await assertNoDiagnosticsInFile(_appFile);
  }
}
