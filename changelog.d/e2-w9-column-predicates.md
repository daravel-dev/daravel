### Added

- ORM: typed conditions on typed columns (wave 9, W9.2): `User.cols.age.gte(18)`, `.eq`, `.neq` (`IS [NOT] NULL` for null), `.gt`, `.lt`, `.lte`, `.between`, `.notBetween`, `.inValues`, `.notInValues`, `.isNull`, `.isNotNull`, and on text columns `.like`, `.startsWith`, `.endsWith`, `.contains`, for `where` and `orWhere`. The value must have the column's type, a comparison's bound is never null, and text conditions do not exist on number columns: mistakes do not compile. Each condition is the node `where(column, operator, value)` builds, so the SQL and the bindings are the string form's.
- `startsWith`, `endsWith` and `contains` take their text literally: `%`, `_` and `!` in it are escaped, and the SQL adds `ESCAPE '!'` (`BasicWhere.escaped`, `BasicWhere.escapeLike`), the same on SQLite, PostgreSQL and MySQL.

### Changed

- `QueryBuilder.where`/`orWhere` take a typed condition (`ColumnPredicate`); the refusal of a `bool` now also shows `where(User.cols.email.eq(value))`.

### Upgrade notes

- `package:daravel` exports `ColumnPredicate` and the extensions `NullableColumnConditions`, `ComparableColumnConditions`, `TextColumnConditions`; `BasicWhere` has a new named parameter `escaped` (default false). An application type of one of these names now needs a prefix or `hide`.
- `where(column, operator, value)` checks the operator when it is called (`ArgumentError` "Unsupported SQL operator"), as the typed conditions do, instead of when the query is compiled; same error type and message, earlier. A typed condition given an extra operator or value (`where(User.cols.age.gte(18), 5)`) is an `ArgumentError` instead of the extra argument being ignored.
