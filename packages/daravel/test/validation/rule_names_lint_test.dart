import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_lints/daravel_lints.dart';
import 'package:test/test.dart';

/// `daravel_lints` cannot depend on the framework, so the lint keeps its own
/// copy of the rule names; this keeps it equal to `RuleParser`.
void main() {
  final source = File('lib/src/validation/rule_parser.dart').readAsStringSync();
  final parserNames = {
    for (final arm in RegExp(
      r"^\s+((?:'[a-z0-9_]+'(?: \|\| )?)+) =>",
      multiLine: true,
    ).allMatches(source))
      for (final name in RegExp("'([a-z0-9_]+)'").allMatches(arm[1]!)) name[1]!,
  };

  test('the lint knows exactly the rules RuleParser parses', () {
    expect(parserNames, hasLength(greaterThan(60)));
    expect(InvalidValidationRule.knownRules, unorderedEquals(parserNames));
  });

  test('rules that need arguments parse with them and are flagged without', () {
    for (final MapEntry(key: rule, value: count)
        in InvalidValidationRule.requiredArguments.entries) {
      final args = switch (rule) {
        'regex' || 'not_regex' => '/x/',
        _ => List.filled(count, '1').join(','),
      };
      expect(
        () => RuleParser.parse('$rule:$args'),
        returnsNormally,
        reason: rule,
      );
      expect(
        InvalidValidationRule.problemIn('$rule:$args'),
        isNull,
        reason: rule,
      );
      // RuleParser accepts some of these with no list (`mimes` → no
      // extension ever matches); Laravel refuses them, and so does the lint.
      expect(InvalidValidationRule.problemIn(rule), isNotNull, reason: rule);
    }
  });
}
