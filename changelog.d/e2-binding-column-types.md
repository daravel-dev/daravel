### Added

- `DataExceptionErrors` (a driver's `isDataException`), `DatabaseManager.isDataException(error, connection:)` and `PostgresDriver.isDataException`: whether a query failed because the database could not read a value as its column's type (SQLSTATE class 22). `SchemaBuilder.changes` counts the tables a schema builder of the isolate created, altered, renamed or dropped.

### Changed

- Route model binding by a custom column (`{post:number}`) reads the value from the URL as the column's type first, as PostgreSQL reads it: an integer column takes an integer within its range (spaces around it, a sign and leading zeros are fine, so `007` finds 7), a decimal column a plain decimal, and anything else is a `404` on every database. A PostgreSQL data exception from the lookup (a uuid, date or boolean of another shape) is a `404` too, inside a transaction through a savepoint. The column types come from `Schema.getColumns`, once per connection and table in each isolate (a schema builder's change reads them again): measured, the first such request costs about 0.5 ms more on SQLite, 10 ms on PostgreSQL and 24 ms on MySQL, later ones nothing. Binding by the primary key reads no schema and keeps its SQL; a uuid or string key the database refuses (PostgreSQL, `abc` for a uuid) is a `404` too, through the same savepoint inside a transaction. Guide: [Routing](docs/guide/routing.md#route-model-binding).

### Upgrade notes

- Upgrading can change which model a URL binds: on MySQL, `{post:number}` with `abc` or `7abc` bound the row whose number is 0 or 7 (as Laravel does, MySQL coercing the text), and `7.0` the row 7; these are now a `404`. On PostgreSQL the same values were a `500` and are now a `404`. A column changed by raw SQL or by another process while the application runs is read with its old type until a restart. New public name `DataExceptionErrors` in `package:daravel` (an application class of that name and the barrel import give an ambiguous-import error; `hide` it or rename yours).
