import 'dart:io';

import 'package:daravel_lints/daravel_lints.dart';
import 'package:test/test.dart';

/// `prefer_sql_identifier` judges a query that starts at a model's static
/// (`Region.where(sort)`) at the caller (#322): the passthrough in the
/// statics region is left alone, the argument it is given is not.
void main() {
  const rule = PreferSqlIdentifier(modelClasses: {'Region'});

  List<int> lines(String source, {PreferSqlIdentifier with_ = rule}) => [
    for (final issue in lintSource(source, 'lib/app/a.dart', rules: [with_]))
      issue.line,
  ];

  test("a model's static start is judged; accepted columns pass", () {
    const source = '''
void f(String sort, String x) {
  Region.where(sort);
  Region.where('code', 1);
  Region.where(Region.cols.code, 1);
  Region.where(SqlIdentifier(x), 1);
  Region.orderBy(sort);
  Foo.where(sort);
}
''';
    expect(lines(source), [2, 6]);
    // Without the model classes, as before #322: none of them.
    expect(lines(source, with_: const PreferSqlIdentifier()), isEmpty);
  });

  test("the model's own statics region is still not reported", () {
    const source = '''
final class Region extends Model {
  // <dartisan:statics>
  static ModelQuery<Region> where(Object column, [Object? a, Object? b]) =>
      query().where(column, a, b);
  // </dartisan:statics>
}
''';
    expect(lines(source), isEmpty);
  });

  test('model classes: extends Model, directly or through the folder', () {
    final index = ModelColumnIndex.ofSources([
      'abstract class BaseModel extends Model {}',
      'final class Region extends BaseModel {}',
      'final class Post extends Model {}',
      'final class Helper {}',
      'final class Widget extends StatelessWidget {}',
      // A chain that leaves the folder is not guessed.
      'final class Remote extends ExternalBase {}',
      // A cycle ends.
      'class A extends B {}\nclass B extends A {}',
    ]);
    expect(index.modelClasses, {'BaseModel', 'Region', 'Post'});
  });

  test('rulesIn gives prefer_sql_identifier the project models', () {
    final root = Directory.systemTemp.createTempSync('caller_judging');
    addTearDown(() => root.deleteSync(recursive: true));
    File('${root.path}/lib/app/models/base_model.dart')
      ..createSync(recursive: true)
      ..writeAsStringSync('abstract class BaseModel extends Model {}\n');
    File('${root.path}/lib/app/models/region.dart')
        .writeAsStringSync('final class Region extends BaseModel {}\n');
    final config = LintConfig(enabled: ['prefer_sql_identifier']);
    final built = config.rulesIn(root.path).whereType<PreferSqlIdentifier>();
    expect(built.single.modelClasses, {'BaseModel', 'Region'});
    // rules (no project) keeps the plain one.
    expect(
      config.rules.whereType<PreferSqlIdentifier>().single.modelClasses,
      isEmpty,
    );
    // Not enabled: no model folder is read, nothing changes.
    expect(LintConfig().rulesIn(root.path), LintConfig().rules);
  });
}
