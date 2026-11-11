import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/src/model_sync.dart';
import 'package:dartisan_cli/src/stubs.dart';
import 'package:test/test.dart';

/// The generated `where` static defaults its optional arguments to
/// `QueryBuilder.absent`, and `model:sync` warns about one written before
/// that, which passes `null` on (#241).
void main() {
  const columns = [
    ColumnInfo(name: 'id', type: 'INTEGER', nullable: false, primary: true),
  ];

  test('make:model writes the where static with the absent defaults', () {
    final made = renderStub(builtInStubs['model']!, {
      'class': 'Lesson',
      'table': 'lessons',
      'softDeletes': '',
    });
    expect(made, contains('Object? operatorOrValue = QueryBuilder.absent,'));
    final synced = syncModelSource(made, ModelSource.parse(made)!, columns);
    expect(synced.warnings.where((w) => w.contains('where static')), isEmpty);
    expect(staticLines('Lesson'), containsAll(whereStaticLines('Lesson')));
  });

  test('a where static that passes null on gets one warning with the fix', () {
    const old = '''
final class Exam extends Model {
  static final ModelDefinition<Exam> definition = ModelDefinition<Exam>(
    table: 'exams',
    factory: Exam.new,
  );

  // <dartisan:statics>
  static ModelQuery<Exam> query() => definition.query();
  static ModelQuery<Exam> where(Object column, [Object? op, Object? value]) =>
      query().where(column, op, value);
  // </dartisan:statics>

  // <dartisan:accessors>
  // </dartisan:accessors>
}
''';
    final synced = syncModelSource(old, ModelSource.parse(old)!, columns);
    final warnings = [
      for (final w in synced.warnings)
        if (w.contains('where static')) w,
    ];
    expect(warnings, hasLength(1));
    expect(
      warnings.single,
      startsWith('Exam: the where static passes null on'),
    );
    expect(warnings.single, contains(whereStaticLines('Exam').join('\n')));
    // The application's region is left as it is.
    expect(synced.source, contains('query().where(column, op, value);'));
  });

  test('a where static outside the statics region is not looked at', () {
    expect(
      whereStaticWarning(
        'static ModelQuery<X> where(Object c, [Object? o, Object? v]) => '
            'query().where(c, o, v);',
        'X',
      ),
      isNull,
    );
  });
}
