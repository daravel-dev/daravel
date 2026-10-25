# Changelog

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
