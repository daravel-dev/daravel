### Added

- `Rules.requiredIfIn(other, values)` and `Rules.requiredUnlessIn(other, values)` (also chain steps): `required_if` and `required_unless` with several values, as `required_if:role,admin,owner`.

### Fixed

- `required_if` and `required_unless` read only their first value: `required_if:role,admin,owner` did not require the field when `role` was `owner`. They now read every value and compare as Laravel 13's `parseDependentRuleParameters` does.
- In that comparison, `'true'`/`'false'` are booleans for a boolean input or a field with a `boolean` rule (`'1'` then matches `true`), and `'null'` (any case) is null for a null input.
- The comparison is strict for a bool or null input and PHP's loose `==` otherwise: `'05'` and `5.0` match `5`, `'1e1'` matches `10`, and `'0x1A'` matches nothing.
- `required_if` no longer requires the field when the other field is missing, as Laravel's `Arr::has` check.
- The messages follow Laravel: `required_if`'s `:value` is the other field's input (the value that matched, not the rule's first value), and `required_unless`'s `:values` lists every value.

### Upgrade notes

- `RequiredIfRule.expected` and `RequiredUnlessRule.expected` are now the first of the new `values`. The `parameters` map of `required_unless` holds every value joined with `, `.
- A rule that relied on the old text comparison changes meaning: `required_if:qty,5` now requires the field for `'05'` or `5.0`, and `required_if:role,admin` no longer requires it when `role` is absent.
- New public names `Rules.requiredIfIn`, `Rules.requiredUnlessIn` and the `RequiredIfRule.oneOf` / `RequiredUnlessRule.oneOf` constructors.
