// test_reflective_loader runs the methods named test_..., so they cannot be
// lowerCamelCase.
// ignore_for_file: non_constant_identifier_names

import 'package:analysis_server_plugin/edit/dart/correction_producer.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/file_system/memory_file_system.dart';
import 'package:analyzer_plugin/protocol/protocol_common.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_core.dart';
import 'package:analyzer_testing/analysis_rule/analysis_rule.dart';
import 'package:analyzer_testing/utilities/extensions/resource_provider.dart';
import 'package:daravel_lints_plugin/daravel_lints_plugin.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

/// `string_column_name` in the editor (W9.8 PR 2): the models of each
/// file's package, cached and refreshed, and the fix to the `cols` token.
void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(StringColumnNameTest);
  });

  group('ModelIndexCache', () {
    late MemoryResourceProvider provider;
    String path(String p) => ResourceProviderExtension(provider).convertPath(p);

    const user = '''
final class User extends Model {
  static const cols = (email: ModelColumn<User, String>('email'));
}
''';

    setUp(() {
      provider = MemoryResourceProvider();
      provider.newFile(path('/app/pubspec.yaml'), 'name: app\n');
      provider.newFile(path('/app/lib/app/models/user.dart'), user);
    });

    test('per package, cached, rebuilt when a model changes', () {
      final cache = ModelIndexCache();
      final file = provider.newFile(path('/app/lib/app/q.dart'), '');
      final first = cache.indexFor(file);
      expect(first.fieldOf('User', 'email'), 'email');
      // Unchanged models: the same index.
      expect(identical(cache.indexFor(file), first), isTrue);
      // A changed model (as an unsaved edit reaches the server): rebuilt.
      provider.modifyFile(
        path('/app/lib/app/models/user.dart'),
        user.replaceFirst('email: ', 'mail: '),
      );
      expect(cache.indexFor(file).fieldOf('User', 'email'), 'mail');
      // A new model file counts too.
      provider.newFile(path('/app/lib/app/models/post/post.dart'), '''
final class Post extends Model {
  static const cols = (title: ModelColumn<Post, String>('title'));
}
''');
      expect(cache.indexFor(file).fieldOf('Post', 'title'), 'title');
    });

    test('empty outside a package or without models', () {
      final cache = ModelIndexCache();
      final loose = provider.newFile(path('/loose/a.dart'), '');
      expect(cache.indexFor(loose).models, isEmpty);
      provider.newFile(path('/other/pubspec.yaml'), 'name: other\n');
      final other = provider.newFile(path('/other/lib/a.dart'), '');
      expect(cache.indexFor(other).models, isEmpty);
    });
  });
}

@reflectiveTest
class StringColumnNameTest extends AnalysisRuleTest {
  static const _query = '''
import 'models/user.dart';

Future<void> f() => User.query().select(const ['id', 'email']).get();
''';

  @override
  void setUp() {
    rule = DaravelAnalysisRule.stringColumnName(ModelIndexCache());
    super.setUp();
    newFile('$testPackageRootPath/lib/app/models/user.dart', '''
class ModelColumn<M, T> {
  const ModelColumn(this.name);
  final String name;
}
class Query {
  Query select(List<Object> columns) => this;
  Future<void> get() async {}
}
final class User {
  static Query query() => Query();
  static const cols = (
    id: ModelColumn<User, int>('id'),
    email: ModelColumn<User, String>('email'),
  );
}
''');
  }

  String get _appFile => '$testPackageRootPath/lib/app/query.dart';

  Future<void> test_reports_from_the_package_models() async {
    newFile(_appFile, _query);
    final source = normalizeSource(_query);
    await assertDiagnosticsInFile(_appFile, [
      lint(source.indexOf("'id'"), 4),
      lint(source.indexOf("'email'"), 7),
    ]);
  }

  Future<void> test_fix_all_in_file() async {
    newFile(_appFile, _query);
    final unit = await resolveFile(_appFile);
    final library = await unit.session.getResolvedLibrary(
      unit.path,
    ) as ResolvedLibraryResult;
    final found = [
      for (final d in unit.diagnostics)
        if (d.diagnosticCode.lowerCaseName == 'string_column_name') d,
    ];
    expect(found, hasLength(2));
    final analysisRule = rule as DaravelAnalysisRule;
    final builder = ChangeBuilder(session: unit.session);
    final messages = <String>[];
    for (final diagnostic in found) {
      final producer = DaravelFix(
        analysisRule.rule,
        ruleIn: analysisRule.ruleIn,
        context: CorrectionProducerContext.createResolved(
          libraryResult: library,
          unitResult: unit,
          diagnostic: diagnostic,
          applyingBulkFixes: true,
          selectionOffset: diagnostic.offset,
          selectionLength: diagnostic.length,
        ),
      );
      await producer.compute(builder);
      messages.add(producer.fixArguments.single);
    }
    expect(messages, [
      'Write as User.cols.id (removes const)',
      'Write as User.cols.email (removes const)',
    ]);
    expect(
      SourceEdit.applySequence(
        normalizeSource(_query),
        builder.sourceChange.edits.single.edits,
      ),
      normalizeSource('''
import 'models/user.dart';

Future<void> f() => User.query().select([User.cols.id, User.cols.email]).get();
'''),
    );
  }
}
