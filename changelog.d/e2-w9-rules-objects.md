### Added

- Laravel's object rules (wave 9, W9.4a): `Rules.when` / `Rules.whenInput` and `Rules.unless` / `Rules.unlessInput` (`Rule::when`/`Rule::unless`, decided once per validation on the whole input, as `filterConditionalRules`), `Rules.forEach` and `Rules.forEachNested` (`Rule::forEach`, rules built per element; keyed rules validate keys of each element and are part of `validated()`), and `Rules.anyOf` / `Rules.anyOfKeyed` (`Rule::anyOf`, each alternative validated on the value alone, with Laravel's `any_of` message). Each is also a chain step. `when`/`unless`/`forEach` nest at most `Validator.maxRuleNesting` (8) levels, so a `forEach` that returns itself fails with an error naming the attribute instead of looping; Laravel has no limit.

### Upgrade notes

- `package:daravel` exports `ConditionalRule`, `ForEachRule`, `AnyOfRule`, `ExpandingRule` and the `ForEachItem` record type (from `src/validation/object_rules.dart`).
