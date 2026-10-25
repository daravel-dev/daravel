# Changelog

## 1.1.0

- Version aligned with Daravel 1.1.0; the framework's ORM, transaction and cache concurrency suites now also run on MySQL 8.4 and MariaDB 11.

## 1.0.0

- First release, together with Daravel 1.0.0: `MySqlDriver` for MySQL 8.4 and MariaDB 10.11+, registered
  with `withDatabaseDriver('mysql', MySqlDriver.fromConfig)`.
