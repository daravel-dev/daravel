/// MySQL and MariaDB driver for Daravel (ADR-019).
///
/// ```dart
/// Application.configure(basePath: '.')
///     .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
///     .withDatabaseDriver('mariadb', MySqlDriver.fromConfig)
/// ```
library;

export 'src/mysql_driver.dart';
