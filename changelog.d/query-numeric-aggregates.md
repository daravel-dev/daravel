### Changed

- `sum()` without rows (or with only `NULL` values) returns `0`, as Laravel's `sum` (`$result ?: 0`), instead of `null`; `avg()`, `min()` and `max()` still return `null` there. The return type stays `Future<num?>`. (1.27.2 fixed the cast error of `sum()` and `avg()` on PostgreSQL and MySQL and kept `null` there.)

### Upgrade notes

- `sum()` without rows is now `0`, not `null`: code that checked `sum(...) == null` for "no rows" should use `count()` or `exists()`.
