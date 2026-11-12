### Added

- `daravel_lints` (W9.8): the opt-in rule `string_column_name` (`StringColumnName`) reports a column name written as a string in a model query (`User.query().where('email', x)`, `User.where(...)`), and its message names the typed token (`User.cols.email`).
- It reports only where that model's `cols` record holds the column, and only in a method that takes a typed column: `where`, `orWhere`, `orderBy`, `orderByDesc`, `latest`, `oldest`, `pluck`, `increment`, `decrement`, `min`, `max`, `sum`, `avg`, `count`, `select` and `groupBy`. So the editor fix that follows always compiles.
- `ModelColumnIndex` reads the field of each column from the `cols` region `dartisan model:sync` writes, never deriving it from the column's name. `StringColumnName.forProject(root)` builds the rule from `lib/app/models`; a model directory that cannot be read leaves the rule silent, with a warning.
- `packages/daravel/test/database/string_column_equivalence_test.dart` runs every method in the rule's lists once with the string and once with the token, and expects the same SQL, bindings and results.

### Upgrade notes

- New public names `StringColumnName` and `ModelColumnIndex` in `package:daravel_lints`. If an application declares either name, importing `package:daravel_lints` makes the reference ambiguous; `hide` the package's name or rename yours. The rule is opt-in.
