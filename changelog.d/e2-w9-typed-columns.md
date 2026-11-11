### Added

- ORM: typed columns (wave 9, W9.1). `dartisan model:sync` writes `static const cols = (...)` into a model's accessors region, one `ModelColumn<Model, Type>` per column, so `User.cols.` lists the columns in the editor and a misspelt one does not compile. A token is the column's name at run time: the SQL is the string's. `where`, `orderBy`, `orderByDesc`, `select`, `groupBy`, the aggregates and now `latest`, `oldest`, `value` and `pluck` take it; elsewhere write `User.cols.email.name`.
- Tests: `test/typed_api/compile_negative_test.dart` (tag `typed-api`) analyzes snippets that must, or must not, compile against the typed API.

### Changed

- `QueryBuilder.latest`/`oldest`/`value`/`pluck` and `ModelQuery.latest`/`oldest`/`pluck` take `Object` columns (a `String` or a typed column); anything else is an `ArgumentError` naming the parameter.
- `model:sync` names accessors and `cols` fields with one rule: a column whose camelCase name is an `Object` member (`to_string`), not a Dart name (`1st_name`) or already taken by an earlier column gets no accessor (such a file did not compile before) and a `cols` field that is valid (`toStringColumn`, `c1stName`, `lftColumn`), with a warning naming it.

### Upgrade notes

- `package:daravel` exports `ModelColumn`. An application type of that name now needs a prefix or `hide`.
- Run `dartisan model:sync` to add `cols` to existing models; until then they work as before.
