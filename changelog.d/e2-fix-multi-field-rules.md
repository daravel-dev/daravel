### Added

- `Rules.differentFrom(others)` and `Rules.excludeWithoutAny(others)` (also chain steps): `different` and `exclude_without` over several fields, as `different:a,b` and `exclude_without:a,b`.

### Fixed

- `different:a,b` read only its first field. Following Laravel 13's `validateDifferent`, it now fails when the value is identical to any of the fields that is present; an absent field is skipped.
- `exclude_without:a,b` read only its first field. It now leaves the field out when any of them is absent or empty, as Laravel's `anyFailingRequired`.
- `same` and `different` compared the values as text. They now compare as PHP's `===`: `5` is not `'5'` or `5.0`, and lists and maps must match element by element.
- `unique` and `exists` written as strings ignored the `column,value` where conditions Laravel reads after their arguments (`exists:users,id,active,1`), which loosened the rule. The string form now refuses them with an error naming `Rules.unique(...).where(...)` / `Rules.exists(...).where(...)`.

### Upgrade notes

- A `same`/`different` rule that relied on the text comparison changes meaning: `same:b` now fails for `5` against `'5'`.
- A string `unique:` with more than four arguments, or `exists:` with more than two, is now an `ArgumentError` when the rules are parsed (at boot or in a test). Write the conditions with the object form.
- New public names `Rules.differentFrom`, `Rules.excludeWithoutAny` and the `SameRule.differentFrom` constructor.
