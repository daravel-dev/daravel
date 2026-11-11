// test_reflective_loader runs the methods named test_..., so they cannot be
// lowerCamelCase.
// ignore_for_file: non_constant_identifier_names

import 'package:analyzer/dart/ast/ast.dart';
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
    defineReflectiveTests(OneWalkTest);
    defineReflectiveTests(NoInlineJsInterpolationTest);
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
  // The `whereRaw` call starts at 98; its interpolated SQL at 111.
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
    await assertDiagnosticsInFile(_appFile, [
      lint(
        111,
        10,
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

/// Counts its walks; reports each `print` call.
final class _CountingRule extends LintRule {
  const _CountingRule();

  static int checks = 0;
  static int checksAt = 0;

  @override
  String get name => 'counting_rule';

  @override
  String get description => 'Counts check() calls.';

  @override
  void check(CompilationUnit unit, void Function(AstNode, String) report) {
    checks++;
    for (final declaration in unit.declarations) {
      report(declaration, 'found');
    }
  }

  @override
  void checkAt(CompilationUnit unit, void Function(int, String) report) {
    checksAt++;
    super.checkAt(unit, report);
  }
}

@reflectiveTest
class OneWalkTest extends AnalysisRuleTest {
  @override
  void setUp() {
    _CountingRule.checks = 0;
    _CountingRule.checksAt = 0;
    rule = DaravelAnalysisRule(const _CountingRule());
    super.setUp();
  }

  Future<void> test_a_rule_reporting_at_nodes_walks_the_file_once() async {
    final path = '$testPackageRootPath/lib/app/a.dart';
    newFile(path, 'void a() {}\n');
    await assertDiagnosticsInFile(path, [lint(0, 11)]);
    // The test harness may analyze the file more than once; each analysis
    // runs check() alone, never checkAt() (which would walk it again).
    expect(_CountingRule.checks, greaterThan(0));
    expect(_CountingRule.checksAt, 0);
  }
}

@reflectiveTest
class NoInlineJsInterpolationTest extends AnalysisRuleTest {
  static const String _page =
      r'''String page(String name) => '<button onclick="go(\'$name\')">';'''
      '\n';

  @override
  void setUp() {
    rule = DaravelAnalysisRule(const NoInlineJsInterpolation());
    super.setUp();
  }

  Future<void> test_reports_inside_the_string_where_the_value_is() async {
    final path = '$testPackageRootPath/lib/resources/page.dart';
    newFile(path, _page);
    await assertDiagnosticsInFile(path, [
      lint(
        _page.indexOf(r'$name'),
        1,
        messageContainsAll: ['inline on* handler'],
      ),
    ]);
  }
}
