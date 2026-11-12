// test_reflective_loader runs the methods named test_..., so they cannot be
// lowerCamelCase.
// ignore_for_file: non_constant_identifier_names

import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:daravel_lints_plugin/daravel_lints_plugin.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

/// `prefer_sql_identifier` in the editor judges `Region.where(sort)` at the
/// caller (#322), knowing from the resolved class that `Region` is a model,
/// also through a base class.
void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(PreferSqlIdentifierModelsTest);
  });
}

@reflectiveTest
class PreferSqlIdentifierModelsTest extends AnalysisRuleTest {
  @override
  void setUp() {
    rule = DaravelAnalysisRule.preferSqlIdentifier(ModelIndexCache());
    super.setUp();
    // Model lives outside lib/app/models (as in package:daravel).
    newFile('$testPackageRootPath/lib/src/model.dart', '''
class Query {
  Query where(Object column, [Object? value]) => this;
}
abstract class Model {}
''');
    newFile('$testPackageRootPath/lib/app/models/base_model.dart', '''
import '../../src/model.dart';
abstract class BaseModel extends Model {}
''');
    newFile('$testPackageRootPath/lib/app/models/region.dart', '''
import '../../src/model.dart';
import 'base_model.dart';
final class Region extends BaseModel {
  static Query where(Object column, [Object? value]) =>
      Query().where(column, value);
}
''');
  }

  String get _appFile => '$testPackageRootPath/lib/app/regions.dart';

  Future<void> test_a_model_static_is_judged_at_the_caller() async {
    const source = '''
import 'models/region.dart';

void f(String sort) {
  Region.where(sort);
  Region.where('code');
}
''';
    newFile(_appFile, source);
    await assertDiagnosticsInFile(_appFile, [
      lint(normalizeSource(source).indexOf('sort);'), 4),
    ]);
  }

  Future<void> test_a_class_that_is_not_a_model_is_not() async {
    const source = '''
import 'src/model.dart';

final class Finder {
  static Query where(Object column, [Object? value]) => Query();
}

void f(String sort) => Finder.where(sort);
''';
    newFile('$testPackageRootPath/lib/finder.dart', source);
    await assertNoDiagnosticsInFile('$testPackageRootPath/lib/finder.dart');
  }
}
