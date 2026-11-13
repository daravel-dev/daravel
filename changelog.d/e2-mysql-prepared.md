### Added

- `DB.unprepared(sql)` (Laravel's `DB::unprepared`), `DatabaseManager.unprepared`: runs a script of several statements, or one the server cannot prepare, on MySQL/MariaDB (text protocol), PostgreSQL (simple query protocol) and SQLite (`sqlite3_exec`). Drivers expose it through the `UnpreparedExecutor` interface; `MultipleStatementsException` is SQLite's refusal of a second statement. `dartisan lint` (`no_sql_string_interpolation`) checks `unprepared` too.

### Fixed

- Security: on MySQL and MariaDB, `DB.select`, `DB.statement` and `DB.insertGetId` without bindings ran every statement in their SQL (`SELECT 1; DROP TABLE users`): `mysql_dart` sends such a statement as text on a connection that announces multi-statement support. Each new text without bindings is now checked with a prepare, closed at once, and remembered per connection (256 texts of up to 4 096 characters; a `SET` or `CALL` forgets them, since `sql_mode` and the character set change how text splits), so a second statement fails with the server's syntax error and nothing runs. Laravel prepares these statements (`ATTR_EMULATE_PREPARES => false`). A statement the prepared protocol does not support (1295) runs as text, as `pdo_mysql` falls back for it. A repeated text costs nothing extra; a text new to a connection costs one more round trip. Since 1.0.0.
- Security: on SQLite, `DB.statement` and `DB.insertGetId` without bindings ran every statement in their SQL (`sqlite3_exec`). They now refuse a second statement, as `select` and every call with bindings already did, with a `QueryException` whose `previous` is a `MultipleStatementsException` (`select`'s refusal used to escape as a bare `ArgumentError`). Laravel on SQLite runs the first statement and drops the rest without an error; refusing is deliberate. Since 1.0.0.

### Upgrade notes

- Upgrading can break a migration or seeder that runs several statements in one `DB.statement` (SQLite, MySQL, MariaDB): run such a script with `DB.unprepared`. New public names: `DB.unprepared`, `DatabaseManager.unprepared`, `UnpreparedExecutor`, `MultipleStatementsException`, `MySqlDriver.unprepared`, `MySqlDriver.singleStatementCacheSize`, `MySqlDriver.singleStatementMaxLength`, `SqliteDriver.unprepared`, `PostgresDriver.unprepared`.
