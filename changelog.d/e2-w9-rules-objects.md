### Added

- Laravel's object rules (wave 9, W9.4a): `Rules.when` / `Rules.whenInput` and `Rules.unless` / `Rules.unlessInput` (`Rule::when`/`Rule::unless`, decided once per validation on the whole input, as `filterConditionalRules`), `Rules.forEach` and `Rules.forEachNested` (`Rule::forEach`, rules built per element; keyed rules validate keys of each element and are part of `validated()`), and `Rules.anyOf` / `Rules.anyOfKeyed` (`Rule::anyOf`, each alternative validated on the value alone, with Laravel's `any_of` message). Each is also a chain step. `when`/`unless`/`forEach` nest at most `Validator.maxRuleNesting` (8) levels, so a `forEach` that returns itself fails with an error naming the attribute instead of looping; Laravel has no limit.

- The `when`/`unless` rules and the `forEach` rules are expanded for every attribute before any rule runs, as Laravel's `addRules` does. So a dependent rule (`accepted_if:flag,true`, `exclude_if`, `present_if`, ...) compares the other field as a boolean when a `when` or `forEach` gave it a `boolean` rule.

### Fixed

- `exclude_if` and `exclude_with` read a `*` in the other field as the attribute's own item (`items.*.note` with `exclude_if:items.*.on,true`), as Laravel replaces the asterisks of these dependent rules. Before, the other field was looked up with the `*` and never found, so nothing was excluded.

### Upgrade notes

- `package:daravel` exports `ConditionalRule`, `ForEachRule`, `AnyOfRule`, `ExpandingRule` and the `ForEachItem` record type (from `src/validation/object_rules.dart`).
