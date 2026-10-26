/// PostgreSQL driver for Daravel (Blueprint #31).
///
/// ```dart
/// Application.configure(basePath: '.')
///     .withPostgres()
/// ```
///
/// Through Daravel 1.x the driver is built into `package:daravel`, so this
/// package re-exports it and registering it changes nothing. Depending on
/// it now means the import and the registration stay the same in 2.0, when
/// the driver moves here and `package:daravel` no longer depends on the
/// database client.
library;

import 'package:daravel/daravel.dart';

export 'package:daravel/daravel.dart' show PostgresDriver, PostgresSslMode;

/// Registers the PostgreSQL driver.
extension PostgresApplication on ApplicationBuilder {
  /// Uses [PostgresDriver] for connections whose driver is `pgsql` (and the
  /// `postgres` / `postgresql` spellings).
  ApplicationBuilder withPostgres() {
    for (final name in const ['pgsql', 'postgres', 'postgresql']) {
      withDatabaseDriver(name, PostgresDriver.fromConfig);
    }
    return this;
  }
}
