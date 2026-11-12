import 'dart:io';

import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:daravel_lints/daravel_lints.dart';
import 'package:test/test.dart';

/// The fix of `string_column_name` (W9.8 PR 2): the column string becomes
/// the model's `cols` token, and `string_column_name` runs in `dartisan
/// lint` once a project enables it.
void main() {
  const model = '''
final class User extends Model {
  static const cols = (
    id: ModelColumn<User, int>('id'),
    email: ModelColumn<User, String>('email'),
    emailVerifiedAt: ModelColumn<User, DateTime?>('email_verified_at'),
  );
}
''';
  final rule = StringColumnName(ModelColumnIndex.ofSource(model));

  /// [source] with every fix applied (merged, as "fix all in file"), the
  /// fixes, and what is left to report.
  ({List<LintFix> fixes, String fixed, int left}) fixAll(String source) {
    final unit = parseString(content: source).unit;
    final fixes = rule.fixesIn(unit);
    final merger = LintFixMerger();
    for (final fix in fixes) {
      merger.add(fix);
    }
    final fixed = LintFix('all', merger.edits).apply(source);
    var left = 0;
    rule.check(parseString(content: fixed).unit, (_, _) => left++);
    return (fixes: fixes, fixed: fixed, left: left);
  }

  test('each reported column becomes its token, by the field in cols', () {
    const source = '''
Future<void> f() async {
  await User.query().where('email', 'a').orderBy('email_verified_at').get();
  await User.where('id', 1).latest('id').pluck('email', 'id');
  await User.query().select(['id', 'email']).count('id');
}
''';
    final result = fixAll(source);
    expect(result.fixes, hasLength(9));
    expect(
      result.fixes.map((f) => f.message),
      containsAll([
        'Write as User.cols.email',
        'Write as User.cols.emailVerifiedAt',
      ]),
    );
    expect(result.left, 0);
    expect(result.fixed, '''
Future<void> f() async {
  await User.query().where(User.cols.email, 'a').orderBy(User.cols.emailVerifiedAt).get();
  await User.where(User.cols.id, 1).latest(User.cols.id).pluck(User.cols.email, User.cols.id);
  await User.query().select([User.cols.id, User.cols.email]).count(User.cols.id);
}
''');
  });

  test('a const list loses its const, and the message says so', () {
    const source = '''
Future<void> f() => User.query().select(const ['id', 'email']).get();
''';
    final result = fixAll(source);
    expect(result.fixes.first.message, 'Write as User.cols.id (removes const)');
    expect(result.fixed, contains('select([User.cols.id, User.cols.email])'));
    expect(result.left, 0);
  });

  test('not offered in a list typed to hold strings', () {
    const source = '''
Future<void> f() => User.query().select(<String>['id']).get();
''';
    final unit = parseString(content: source).unit;
    var reported = 0;
    rule.check(unit, (node, _) {
      reported++;
      expect(rule.fixFor(unit, node), isNull);
    });
    expect(reported, 1);
  });

  test('only the column argument: a value that names a column is not one', () {
    const source = '''
Future<void> f() => User.query().where('email', 'id').get();
''';
    final unit = parseString(content: source).unit;
    final literals = <SimpleStringLiteral>[];
    unit.accept(_Literals(literals));
    final value = literals.singleWhere((l) => l.value == 'id');
    expect(rule.fixFor(unit, value), isNull);
    expect(fixAll(source).fixed, contains("where(User.cols.email, 'id')"));
  });

  group('enabled in a project', () {
    late Directory root;

    setUp(() {
      root = Directory.systemTemp.createTempSync('string_column_config');
      File('${root.path}/lib/app/models/user.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync(model);
    });
    tearDown(() => root.deleteSync(recursive: true));

    test('a known name; rulesIn builds it over the project models', () {
      expect(LintConfig.knownNames, contains('string_column_name'));
      final off = LintConfig();
      expect(
        off.rulesIn(root.path).map((r) => r.name),
        isNot(contains('string_column_name')),
      );
      final on = LintConfig(enabled: ['string_column_name']);
      // rules needs no project, so it leaves the rule out.
      expect(
        on.rules.map((r) => r.name),
        isNot(contains('string_column_name')),
      );
      final built = on.rulesIn(root.path).whereType<StringColumnName>().single;
      expect(built.index.fieldOf('User', 'email'), 'email');
      final disabled = on.withOverrides(disable: ['string_column_name']);
      expect(
        disabled.rulesIn(root.path).whereType<StringColumnName>(),
        isEmpty,
      );
    });

    test('read from analysis_options.yaml like the other opt-in rules', () {
      File('${root.path}/analysis_options.yaml').writeAsStringSync('''
daravel_lints:
  diagnostics:
    string_column_name: true
''');
      File('${root.path}/lib/app/q.dart')
        ..createSync(recursive: true)
        ..writeAsStringSync(
          "Future<void> f() => User.query().where('email', 1).get();\n",
        );
      final config = lintConfig(root.path);
      final issues = lintProject(
        root.path,
        rules: config.rulesIn(root.path),
        registries: false,
      );
      expect([for (final i in issues) i.rule], ['string_column_name']);
    });
  });
}

final class _Literals extends RecursiveAstVisitor<void> {
  _Literals(this.found);
  final List<SimpleStringLiteral> found;

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) {
    found.add(node);
  }
}
