// Database drivers (explicit, AOT-friendly): read by createApp and by
// `dartisan model:sync`, which syncs the models without compiling the rest
// of the application. sqlite and pgsql are built into package:daravel.
import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';

/// The drivers by the connection `driver` they serve: `DB_CONNECTION=mysql`
/// or `mariadb`.
final Map<String, DatabaseDriverFactory> databaseDrivers = {
  'mysql': MySqlDriver.fromConfig,
  'mariadb': MySqlDriver.fromConfig,
};
