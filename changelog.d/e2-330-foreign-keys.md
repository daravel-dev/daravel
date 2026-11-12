### Added

- `Schema.getForeignKeys(table)` (and `SchemaBuilder.getForeignKeys`), Laravel's `Schema::getForeignKeys` (#330, first part): one `ForeignKeyInfo` per foreign key, with the constraint `name` (null on SQLite, as in Laravel), the `columns` and the `foreignColumns` of `foreignTable` they reference in order (empty when the DDL leaves them out, `REFERENCES parent`; Laravel gives `[""]`), `foreignSchema`, and the `onUpdate`/`onDelete` actions in lower case. The queries are those of Laravel 13's grammars for SQLite, PostgreSQL and MySQL/MariaDB, checked against what Laravel 13.40 returns on SQLite and run on PostgreSQL 16 and MySQL 8.4.

### Upgrade notes

- New public names in `package:daravel/daravel.dart`: `ForeignKeyInfo`, `Schema.getForeignKeys`, `SchemaBuilder.getForeignKeys`, and on `SchemaGrammar` the members `compileForeignKeys`, `foreignKeyBindings`, `foreignKeyInfo` and `foreignKeyAction`. A `SchemaGrammar` written outside Daravel still compiles: `compileForeignKeys` throws `UnsupportedError` there until it implements it, and `getForeignKeys` then fails with that message.
