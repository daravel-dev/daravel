### Added

- `distinct:strict` and `distinct:ignore_case` are now read (they were ignored), with `Rules.distinct(strict: true, ignoreCase: true)`, the same named parameters on the rule builder, and the fields `DistinctRule.strict` and `DistinctRule.ignoreCase`.

### Changed

- `distinct` and `in_array` now decide as Laravel 13 does, checked against a golden of 1 203 cases run through Laravel 13.40 and a fuzz against a quadratic reference written from Laravel's code. `distinct` compares every value the attribute's pattern matches, by PHP 8's `==` unless `strict`: `[1, 1.0]`, `['1', '1.0']`, `[true, 1]`, `[null, '']` and `[0, '0.0']` now fail, where the text comparison passed them. With `distinct:strict`, `[1, '1']` now passes. With `distinct:ignore_case`, `['a', 'A']` fails, and values are compared as PHP writes them (`0.1 + 0.2` matches `'0.3'`). `in_array:others.*` is strict, as Laravel's: `1` against `[1.0]` now fails; its `*` matches any text, dots and line breaks included (`Str::is`).
- Where validation casts a float to text as PHP does, it now writes it as PHP's `(string)` does, with 14 significant digits (`0.1 + 0.2` is `0.3`, `-0.0` is `-0`, `1e14` is `1.0E+14`), from one function instead of three copies: `:value` in messages (for example `accepted_if`), `doesnt_start_with` and `doesnt_end_with` (`1e14` now starts with `1.0E`), the key a `unique` ignore skips (`1e14` skipped the row `100000000000000`; Laravel skips `1.0E+14`), and the values `exists` on a list counts once (`array_unique`).
- An int and a float now compare as PHP 8 compares them, as floats, in `distinct` and in the rules that compare another field's value (`required_if`, `exclude_if`, `prohibited_if` and the like): above 2^53, `9007199254740993` equals `9007199254740992.0`, where Dart's exact `==` told them apart.

### Fixed

- `distinct` on a nested wildcard (`items.*.tags.*`) never failed, not even for a tag repeated within one item. It now compares the tags of all items, as Laravel's `getDistinctValues` does.
- A numeric string beyond the 64-bit integer range (30 digits, say) compared by `required_if` and the other rules that compare another field's value gave a 500 (`FormatException`); it is now read as a float, as PHP reads it. The fault came with a change on `main` that no release has.
- `in_array` with two or more `*` matched a key in time growing with the square of the key's length (the cube with three `*`), on keys the client writes; keys are now matched in one pass. `in_array` is in no release yet.

### Upgrade notes

- Requests that `distinct` or `in_array` passed can now fail (rules unchanged): a repeated tag under `items.*.tags.*`; `distinct` over values equal as PHP compares them, such as `[1, 1.0]`, `['1', '1.0']`, `[true, 1]` or `[null, '']`; `distinct:ignore_case` over `['a', 'A']`; `in_array` where the value equals one of the others only as a number (`1` against `1.0`). Where a list must accept equal numbers in different forms, validate with `distinct:strict`; where `in_array` must accept `1.0` for `1`, cast the input before validating.
- Where a list or map is among the values of `distinct:ignore_case`, Laravel 13 throws (PHP's array-to-string warning, a 500); Daravel validates the request.
- New public names in `package:daravel/daravel.dart`: `DistinctRule.strict`, `DistinctRule.ignoreCase`, and the parameters `strict` and `ignoreCase` of `Rules.distinct` and `RuleBuilder.distinct`.
