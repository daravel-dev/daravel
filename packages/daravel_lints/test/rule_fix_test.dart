import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:daravel_lints/daravel_lints.dart';
import 'package:test/test.dart';

/// The fix of `string_validation_rule` (W9.8): the literal becomes its
/// `Rules` chain, only where that keeps the meaning and compiles.
void main() {
  const rule = StringValidationRule();

  /// The fixes the rule offers in [source], one per finding (null where it
  /// offers none), and [source] with all of them applied.
  ({List<LintFix?> fixes, String fixed}) fix(String source) {
    final unit = parseString(content: source).unit;
    final nodes = <AstNode>[];
    rule.check(unit, (node, _) => nodes.add(node));
    final fixes = [for (final node in nodes) rule.fixFor(unit, node)];
    var fixed = source;
    // One at a time, re-parsed, as an editor applies them.
    for (var i = 0; i < 20; i++) {
      final next = parseString(content: fixed).unit;
      LintFix? first;
      rule.check(next, (node, _) => first ??= rule.fixFor(next, node));
      if (first == null) {
        break;
      }
      fixed = first!.apply(fixed);
    }
    return (fixes: fixes, fixed: fixed);
  }

  test('a rule string becomes its Rules chain', () {
    const source = '''
import 'package:daravel/daravel.dart';

Future<void> f(Request request) => request.validate({
  'email': 'required|email|max:255',
  'tags': ['required', Rules.array()],
});
''';
    final result = fix(source);
    expect(result.fixes, hasLength(2));
    expect(
      result.fixes.first!.message,
      'Write as Rules.required().email().max(255)',
    );
    expect(
      result.fixed,
      contains("'email': Rules.required().email().max(255),"),
    );
    // In a list next to a Rule: still a list of rules.
    expect(result.fixed, contains("'tags': [Rules.required(), Rules.array()]"));
    // Nothing left to report.
    final unit = parseString(content: result.fixed).unit;
    var left = 0;
    rule.check(unit, (_, _) => left++);
    expect(left, 0);
  });

  test('the import is used as it is written, or added', () {
    const prefixed = '''
import 'package:daravel/daravel.dart' as d;

Future<void> f(d.Request request) => request.validate({'a': 'required'});
''';
    expect(fix(prefixed).fixed, contains("{'a': d.Rules.required()}"));
    const none = '''
import 'dart:async';

Future<void> f(dynamic request) => request.validate({'a': 'required'});
''';
    final added = fix(none).fixed;
    expect(
      added,
      contains("import 'dart:async';\nimport 'package:daravel/daravel.dart';"),
    );
    expect(added, contains("{'a': Rules.required()}"));
    const shown = '''
import 'package:daravel/daravel.dart' show Request, Rules;

Future<void> f(Request request) => request.validate({'a': 'required'});
''';
    expect(fix(shown).fixed, contains("{'a': Rules.required()}"));
  });

  test('an added import goes before the parts; a part gets no fix', () {
    const library = '''
import 'dart:async';

part 'a_part.dart';

Future<void> f(dynamic request) => request.validate({'a': 'required'});
''';
    expect(
      fix(library).fixed,
      startsWith(
        "import 'dart:async';\nimport 'package:daravel/daravel.dart';\n\n"
        "part 'a_part.dart';",
      ),
    );
    const partsOnly = '''
part 'a_part.dart';

Future<void> f(dynamic request) => request.validate({'a': 'required'});
''';
    expect(
      fix(partsOnly).fixed,
      startsWith(
        "import 'package:daravel/daravel.dart';\n\npart 'a_part.dart';",
      ),
    );
    const part = '''
part of 'library.dart';

Future<void> f(dynamic request) => request.validate({'a': 'required'});
''';
    expect(fix(part).fixes, [null], reason: 'a part cannot import');
  });

  test('not offered where Rules is hidden by the import', () {
    for (final combinator in ['show Request', 'hide Rules']) {
      final source =
          '''
import 'package:daravel/daravel.dart' $combinator;

Future<void> f(Request request) => request.validate({'a': 'required'});
''';
      expect(fix(source).fixes, [null], reason: combinator);
    }
  });

  test('a const literal loses its const; a const variable is not touched', () {
    const literal = '''
import 'package:daravel/daravel.dart';

Future<void> f(Request request) => request.validate(const {
  'a': 'required',
  'b': ['required', 'email'],
});
''';
    final constFix = fix(literal);
    // The message says the const goes.
    expect(
      constFix.fixes.first!.message,
      'Write as Rules.required() (removes const)',
    );
    final fixed = constFix.fixed;
    expect(fixed, contains('request.validate({'));
    expect(fixed, contains("'a': Rules.required(),"));
    expect(fixed, contains("'b': [Rules.required(), Rules.email()],"));
    const variable = '''
import 'package:daravel/daravel.dart';

const rules = {'a': 'required'};
Map<String, Object> f() => rules;
final class R extends FormRequest {
  @override
  Map<String, Object> rules() => const {'a': 'required'};
}
''';
    final result = fix(variable);
    // The const map in rules() can drop its const; nothing reports the
    // top-level const (it is not passed to a validator here).
    expect(result.fixed, contains("rules() => {'a': Rules.required()};"));
  });

  test('not offered when one removed const would leave another', () {
    const source = '''
import 'package:daravel/daravel.dart';

Future<void> f(Request request) =>
    request.validate(const {'a': const ['required']});
''';
    final result = fix(source);
    expect(result.fixes, [null]);
    expect(result.fixed, source);
  });

  test('not offered for typed string literals or non-plain strings', () {
    const source = r'''
import 'package:daravel/daravel.dart';

Future<void> f(Request request, String max) => request.validate({
  'a': <String>['required', 'email'],
  'b': 'required|' 'email',
  'c': 'max:$max',
});
Future<void> g(Request request) =>
    request.validate(<String, String>{'d': 'required'});
// An override may narrow rules() to strings; the map is inferred from it.
final class A extends FormRequest {
  @override
  Map<String, String> rules() => {'e': 'required'};
}
final class B extends FormRequest {
  @override
  Map<String, List<String>> rules() {
    return {'f': ['required']};
  }
}
''';
    final result = fix(source);
    // Reported (the message still names the chain), but not fixed.
    expect(result.fixes, hasLength(6));
    expect(result.fixes.whereType<LintFix>(), isEmpty);
    expect(result.fixed, source);
  });

  group('typed by the declaration the literal is written in', () {
    /// The fix of the `'required'` literal in [declaration], asked directly
    /// (most of these places are not reported by the rule; the fix still
    /// refuses them).
    LintFix? fixIn(String declaration) {
      final source = "import 'package:daravel/daravel.dart';\n\n$declaration\n";
      final unit = parseString(content: source).unit;
      final literals = <SimpleStringLiteral>[];
      unit.accept(_Literals(literals));
      return rule.fixFor(
        unit,
        literals.singleWhere((l) => l.value == 'required'),
      );
    }

    final refused = {
      'local variable':
          "void f() {\n  final Map<String, String> r = {'a': 'required'};\n}",
      'nullable value type':
          "void f() {\n  Map<String, String?>? r = {'a': 'required'};\n}",
      'local list': "void f() {\n  List<String> x = ['required'];\n}",
      'list in a map':
          "final Map<String, List<String>> r = {'a': ['required']};",
      'top-level variable': "final Map<String, String> r = {'a': 'required'};",
      'field':
          "final class C {\n  static final Map<String, String> r = "
          "{'a': 'required'};\n}",
      'top-level function': "Map<String, String> rules() => {'a': 'required'};",
      'top-level getter': "Map<String, String> get rules => {'a': 'required'};",
      'method getter':
          "final class C {\n  Map<String, String> get rules => "
          "{'a': 'required'};\n}",
      'local function':
          "void f() {\n  Map<String, String> rules() {\n"
          "    return {'a': 'required'};\n  }\n}",
    };
    for (final MapEntry(key: form, value: declaration) in refused.entries) {
      test('not offered: $form', () => expect(fixIn(declaration), isNull));
    }

    final offered = {
      'Object values': "final Map<String, Object> r = {'a': 'required'};",
      'no type': "final r = {'a': 'required'};",
      'a local function typed Object inside a typed one':
          "Map<String, String> f() {\n"
          "  Object g() {\n    return {'a': 'required'};\n  }\n"
          "  return {};\n}",
    };
    for (final MapEntry(key: form, value: declaration) in offered.entries) {
      test('offered: $form', () => expect(fixIn(declaration), isNotNull));
    }
  });

  test(
    'a fix in a const map inside a const constructor call is not offered',
    () {
      const source = '''
import 'package:daravel/daravel.dart';

final class Holder {
  const Holder(this.rules);
  final Map<String, Object> rules;
}

const holder = Holder({'a': 'required'});
Future<void> f(Request request) =>
    request.validate(const Holder({'a': 'required'}).rules);
''';
      // The rule does not report a map that is not the validator's argument,
      // so there is nothing to fix; the helper refuses the context anyway.
      final unit = parseString(content: source).unit;
      final literals = <SimpleStringLiteral>[];
      unit.accept(_Literals(literals));
      final required = literals.where((l) => l.value == 'required').toList();
      expect(required, hasLength(2));
      for (final literal in required) {
        expect(leaveConstantContext(literal), isNull);
      }
    },
  );

  test('fixes merged: a shared const and import once, overlaps left out', () {
    const source = '''
import 'dart:async';

Future<void> f(dynamic request) =>
    request.validate(const {'a': 'required', 'b': 'email'});
''';
    final unit = parseString(content: source).unit;
    final fixes = rule.fixesIn(unit);
    expect(fixes, hasLength(2));
    final merger = LintFixMerger();
    expect(merger.add(fixes[0]), hasLength(3));
    // Its const removal and import are already there.
    expect(merger.add(fixes[1]), hasLength(1));
    final merged = LintFix('all', merger.edits).apply(source);
    expect(
      merged,
      "import 'dart:async';\nimport 'package:daravel/daravel.dart';\n\n"
      'Future<void> f(dynamic request) =>\n'
      "    request.validate({'a': Rules.required(), 'b': Rules.email()});\n",
    );
    // A fix that overlaps a taken edit is not taken, nor any of its edits.
    expect(merger.add(const LintFix('x', [LintEdit(18, 4, 'y')])), isNull);
    expect(merger.edits, hasLength(4));
    final inserts = LintFixMerger()
      ..add(const LintFix('a', [LintEdit(5, 0, 'a')]));
    expect(inserts.add(const LintFix('b', [LintEdit(5, 0, 'b')])), isNull);
  });

  group('fixSource (dartisan lint --fix)', () {
    test('every fix applied; a silenced finding left alone', () {
      const source = '''
import 'package:daravel/daravel.dart';

Future<void> f(Request request) => request.validate({
  'a': 'required',
  // daravel-lint-ignore: string_validation_rule
  'b': 'email',
  'c': 'max:5',
});
''';
      final fixed = fixSource(source, 'lib/app/a.dart', rules: [rule])!;
      expect(fixed.source, contains("'a': Rules.required(),"));
      expect(fixed.source, contains("'b': 'email',"));
      expect(fixed.source, contains("'c': Rules.max(5),"));
      expect(fixed.messages, [
        'lib/app/a.dart:4: Write as Rules.required()',
        'lib/app/a.dart:7: Write as Rules.max(5)',
      ]);
    });

    test('null when nothing is fixed, or the rule skips the path', () {
      const source =
          "Future<void> f(dynamic r) => r.validate({'a': 'required'});";
      expect(fixSource('void f() {}', 'lib/app/a.dart', rules: [rule]), isNull);
      expect(fixSource(source, 'lib/src/a.dart', rules: [rule]), isNull);
      expect(fixSource(source, 'lib/app/a.dart'), isNull, reason: 'defaults');
    });

    test('a fix left out for an overlap is taken in the next pass', () {
      // Each fix rewrites the whole file: one is taken per pass.
      const overlapping = _Overlapping();
      final fixed = fixSource(
        'final a = 1; final b = 2;',
        'lib/app/a.dart',
        rules: [overlapping],
      )!;
      expect(fixed.source, 'final A = 1; final B = 2;');
      expect(fixed.messages, [
        'lib/app/a.dart:1: Uppercase a',
        'lib/app/a.dart:1: Uppercase b',
      ]);
    });
  });

  test('LintFix applies its edits from the end', () {
    const fix = LintFix('x', [LintEdit(0, 1, 'AB'), LintEdit(2, 1, 'C')]);
    expect(fix.apply('abc'), 'ABbC');
  });
}

/// Reports each top-level variable with a lowercase name; its fix
/// uppercases the name by rewriting the whole file, so any two of its
/// fixes overlap.
final class _Overlapping extends LintRule {
  const _Overlapping();

  @override
  String get name => 'overlapping';

  @override
  String get description => 'test';

  @override
  void check(CompilationUnit unit, void Function(AstNode, String) report) {
    for (final declaration
        in unit.declarations.whereType<TopLevelVariableDeclaration>()) {
      final variable = declaration.variables.variables.single;
      if (variable.name.lexeme.toLowerCase() == variable.name.lexeme) {
        report(declaration, 'lowercase');
      }
    }
  }

  @override
  LintFix? fixFor(CompilationUnit unit, AstNode node) {
    final variable =
        (node as TopLevelVariableDeclaration).variables.variables.single;
    final source = unit.toSource();
    final name = variable.name.lexeme;
    return LintFix('Uppercase $name', [
      LintEdit(
        0,
        unit.end,
        source.replaceFirst('$name =', '${name.toUpperCase()} ='),
      ),
    ]);
  }
}

final class _Literals extends RecursiveAstVisitor<void> {
  _Literals(this.found);
  final List<SimpleStringLiteral> found;

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) => found.add(node);
}
