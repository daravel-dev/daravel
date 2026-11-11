### Added

- Validation: the twelve presence rules of Laravel 13 that Daravel lacked, as strings and as `Rules.*` builders, with Laravel's messages and placeholders: `missing`, `missing_if`, `missing_unless`, `missing_with`, `missing_with_all`, `present_unless`, `present_with`, `present_with_all`, `prohibited_if_accepted`, `prohibited_if_declined`, `required_if_declined`, `required_array_keys`; `invalid_validation_rule` knows them (wave 9, W9.4a).
- Validation: `rule_completeness_test.dart` keeps the string rules, the `Rules.*` builders and the rules of Laravel 13's `lang/en/validation.php` in step; the Laravel rules still missing are listed there by name.

### Upgrade notes

- `package:daravel` exports four new rule classes: `MissingRule`, `PresenceWithRule`, `AcceptanceConditionRule`, `RequiredArrayKeysRule`. An application class of the same name now needs a prefix or `hide`.

### Fixed

- Validation: a `*` in the other field of a dependent rule (`required_with:items.*.b` on `items.*.a`) now means the same item, as Laravel's `getExplicitKeys`/`replaceAsterisksInParameters` do for `$dependentRules`, in the check and in the message (`:other`, `:values`); before, such a field was never found.
