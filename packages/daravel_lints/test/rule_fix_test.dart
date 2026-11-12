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
    final fixed = fix(literal).fixed;
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

  test('LintFix applies its edits from the end', () {
    const fix = LintFix('x', [LintEdit(0, 1, 'AB'), LintEdit(2, 1, 'C')]);
    expect(fix.apply('abc'), 'ABbC');
  });
}

final class _Literals extends RecursiveAstVisitor<void> {
  _Literals(this.found);
  final List<SimpleStringLiteral> found;

  @override
  void visitSimpleStringLiteral(SimpleStringLiteral node) => found.add(node);
}
