### Added

- PostgreSQL: `DB_SSLROOTCERT` (the CA that signed the server certificate), `DB_SSLCERT` and `DB_SSLKEY` (a client certificate), also as `?sslrootcert=`, `?sslcert=`, `?sslkey=` in `DB_URL`, as Laravel's `PostgresConnector` passes them to libpq; `PostgresDriver(securityContext:)` and `PostgresDriver.securityContextOf`. A file that cannot be read, or a certificate without its key, is a `ConfigException` naming the setting.

### Fixed

- Security: a PostgreSQL `DB_SSLMODE` the driver did not know (`required`, a typo) meant no TLS, with only a warning. Any value other than `disable`, `allow`, `prefer`, `require`, `verify-ca` or `verify-full` (any case, `-` or `_`) is now a `ConfigException` naming the six modes: at boot for the default connection, when first used for another. A misspelt `verify-…` is refused too, instead of read as `verify-full`. Since 1.0.0.
- Security: `DB_SSLROOTCERT` was ignored on PostgreSQL, so `verify-full` could only check against the system's CAs and a private CA could not be used. Since 1.0.0.
- MySQL: inside a transaction, a write waiting for a row lock ignored `DB_QUERY_TIMEOUT` and waited for the server's `innodb_lock_wait_timeout` (50 s by default), since `max_execution_time` bounds only `SELECT` and the client backstop is off in a transaction. Each connection now sets `innodb_lock_wait_timeout` to `DB_QUERY_TIMEOUT` (whole seconds, at least 1); the wait ends with error 1205, which `transaction(attempts:)` retries after rolling the whole attempt back. An `initCommands` entry that sets the variable wins.

### Upgrade notes

- Upgrading can stop the boot: a PostgreSQL default connection whose `DB_SSLMODE` is not one of the six libpq modes (for example `required`) now fails with a `ConfigException` instead of connecting without TLS; `DB_SSLROOTCERT` set with `require` gives one warning, since libpq would check the chain and this driver does not (use `verify-full`). On MySQL, a row-lock wait now ends after `DB_QUERY_TIMEOUT` instead of 50 s. New public names: `PostgresDriver.securityContext`, `PostgresDriver.securityContextOf`, `MySqlDriver.lockWaitStatement`.
