# Changelog

## 1.22.0

- Version aligned with Daravel 1.22.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.21.1

- Version aligned with Daravel 1.21.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.21.0

- Version aligned with Daravel 1.21.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.20.1

- Version aligned with Daravel 1.20.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.20.0

- Version aligned with Daravel 1.20.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.19.1

- Version aligned with Daravel 1.19.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.19.0

- Version aligned with Daravel 1.19.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.18.1

- Version aligned with Daravel 1.18.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.18.0

- Added Laravel's `'strict'`, `'modes'` and `'isolation_level'` (`DB_STRICT`, `DB_SQL_MODES`, `DB_ISOLATION_LEVEL`), with the `sql_mode` Laravel 12's `MySqlConnector` sets; `MySqlDriver(initCommands:, onConnectionOpen:)` for anything else on each new connection.
- `select` reads each row in one pass with a reader per column instead of `assoc()` + `typedAssoc()` + a third map, which parsed every DATETIME into a `DateTime` it then discarded: a 1 000 × 40 result takes 10 ms instead of 21 ms (AOT, MariaDB on the same Docker network). Values and types are unchanged, now pinned by an integration test over the text and binary protocols.

## 1.17.0

- Version aligned with Daravel 1.17.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.16.0

- Version aligned with Daravel 1.16.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.15.0

- Version aligned with Daravel 1.15.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.14.0

- Fixed: `close()` waits for in-flight statements (`inFlight`, up to `drainTimeout`) before closing the pool, since `mysql_dart`'s pool close never completes callers still queued for a connection and a graceful shutdown could hang on them; `connect()`'s probe is bounded by `connectTimeout` plus 5 s, since `mysql_dart` opens its socket without a timeout.
- Added `MySqlDriver.queryTimeout` (`DB_QUERY_TIMEOUT`, 30 s; `0` for none) and `DB_CONNECT_TIMEOUT`: statements had no timeout, so one stuck on a lock wait or a half-open connection held its pooled connection for ever. On expiry `mysql_dart` kills the query through a side connection.

## 1.13.0

- Version aligned with Daravel 1.13.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.12.0

- Version aligned with Daravel 1.12.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.11.0

- Version aligned with Daravel 1.11.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.10.1

- Version aligned with Daravel 1.10.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.10.0

- Version aligned with Daravel 1.10.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.9.0

- Version aligned with Daravel 1.9.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.8.1

- Version aligned with Daravel 1.8.1; no changes.

## 1.8.0

- Version aligned with Daravel 1.8.0; no changes.

## 1.7.0

- Version aligned with Daravel 1.7.0; no changes.

## 1.6.0

- Version aligned with Daravel 1.6.0; no changes.

## 1.5.1

- Version aligned with Daravel 1.5.1; no changes.

## 1.5.0

- Version aligned with Daravel 1.5.0; no changes.

## 1.4.1

- Version aligned with Daravel 1.4.1; no changes.

## 1.4.0

- Requires `daravel` 1.4.0; the feature flag store is tested on MySQL and MariaDB.

## 1.3.0

- Requires `daravel` 1.3.0; `mcp:serve`'s `db_query` is tested on MySQL and MariaDB.

## 1.2.0

- Requires `daravel` 1.2.0; the date query shortcut and query guard suites also run on MySQL and MariaDB.

## 1.1.0

- Version aligned with Daravel 1.1.0; the framework's ORM, transaction and cache concurrency suites now also run on MySQL 8.4 and MariaDB 11.

## 1.0.0

- First release, together with Daravel 1.0.0: `MySqlDriver` for MySQL 8.4 and MariaDB 10.11+, registered
  with `withDatabaseDriver('mysql', MySqlDriver.fromConfig)`.
