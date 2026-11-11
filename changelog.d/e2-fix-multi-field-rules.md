### Added

- `Rules.differentFrom(others)` and `Rules.excludeWithoutAny(others)` (also chain steps): `different` and `exclude_without` over several fields, as `different:a,b` and `exclude_without:a,b`.

### Changed

- `same`, `confirmed` and `different` compare as PHP's `===`, as Laravel 13's `validateSame` (which `validateConfirmed` calls) and `validateDifferent` do: `5` is not `'5'` or `5.0`, and lists and maps must match element by element, maps in the same key order. Before, they compared the values as text. Two strings from a form compare as before (`'secret'` confirms `'secret'`, not `'Secret'`).
- `unique` and `exists` written as strings with the `column,value` where conditions Laravel reads after their arguments (`exists:users,id,active,1`) are refused when the rules are parsed: when a `Validator` is built with them, which for a route or a form request is the first request that validates (a 500, with the `ArgumentError` in the log), and when OpenAPI is generated; not at boot. Before, those conditions were silently ignored, so the rule checked less than it said: an `exists:users,id,active,1` accepted an inactive user. The `invalid_validation_rule` lint reports them too.

### Fixed

- `different:a,b` read only its first field. It now fails when the value is identical to any of the fields that is present; an absent field is skipped.
- `exclude_without:a,b` read only its first field. It now leaves the field out when any of them is absent or empty, as Laravel's `anyFailingRequired`.

### Upgrade notes

- A `same`, `confirmed` or `different` rule that relied on the text comparison changes meaning: `confirmed` now fails for a JSON `1234` confirmed by the string `'1234'`. Send both as the same type, or compare them yourself.
- A string `unique:` with more than four arguments, or `exists:` with more than two, is now an `ArgumentError` when a request first validates with it (a 500) or a test does, where it used to drop its conditions. `dartisan lint` (`invalid_validation_rule`) finds these strings before any request. Write the conditions with the object form: `Rules.exists('users', 'id').where(...)`.
- New public names `Rules.differentFrom`, `Rules.excludeWithoutAny` and the `SameRule.differentFrom` constructor.
