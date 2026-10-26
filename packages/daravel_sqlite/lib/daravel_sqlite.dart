/// SQLite driver for Daravel (Blueprint #31).
///
/// ```dart
/// Application.configure(basePath: '.')
///     .withSqlite()
/// ```
///
/// Through Daravel 1.x the driver is built into `package:daravel`, so this
/// package re-exports it and registering it changes nothing. Depending on
/// it now means the import and the registration stay the same in 2.0, when
/// the driver moves here and `package:daravel` no longer depends on the
/// database client.
library;

import 'package:daravel/daravel.dart';

export 'package:daravel/daravel.dart' show SqliteDriver;

/// Registers the SQLite driver.
extension SqliteApplication on ApplicationBuilder {
  /// Uses [SqliteDriver] for connections whose driver is `sqlite`.
  ApplicationBuilder withSqlite() =>
      withDatabaseDriver('sqlite', SqliteDriver.fromConfig);
}
