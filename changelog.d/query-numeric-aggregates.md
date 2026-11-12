### Fixed

- `sum()` and `avg()` of the query builder and model queries threw `type 'String' is not a subtype of type 'num?'` on PostgreSQL and MySQL whenever the database returned a decimal: on PostgreSQL the `avg()` of an integer or decimal column and the `sum()` of a `bigInteger` or `decimal` column, on MySQL every `sum()` and `avg()` of an integer or decimal column. They now read the value by Laravel's `numericAggregate` rule: a string without `.` is an `int`, with one a `double`. `min()` and `max()` still return the driver's value as it is, as Laravel's do (a `decimal` column is a string on PostgreSQL and MySQL). Since 1.0.0 on both.

### Changed

- `sum()` without rows (or with only `NULL` values) returns `0`, as Laravel's `sum` (`$result ?: 0`), instead of `null`; `avg()`, `min()` and `max()` still return `null` there. The return type stays `Future<num?>`.

### Upgrade notes

- `sum()` without rows is now `0`, not `null`: code that checked `sum(...) == null` for "no rows" should use `count()` or `exists()`.
