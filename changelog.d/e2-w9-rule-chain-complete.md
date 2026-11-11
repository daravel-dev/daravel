### Added

- Validation: every `Rules.*` builder is now also a step of the rule chain, on `RuleBuilder` and on any rule (`Rules.required().missingIf('plan', ['free']).gt('min')`): the 36 builders that had no step (`gt`, `gte`, `lt`, `lte`, `decimal`, `multipleOf`, `minDigits`, `maxDigits`, `dateEquals`, `dateFormat`, `timezone`, the `exclude*`, `missing*`, `present*`, `prohibited*` and `required*` families, `requiredArrayKeys`, `enum_`), and `array` on a rule. `rule_completeness_test.dart` checks a fourth direction: every builder is a chain step (wave 9, W9.4).
