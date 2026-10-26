<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_mysql

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_mysql/README.id.md)

MySQL and MariaDB driver for [Daravel](https://pub.dev/packages/daravel),
on the pure Dart [`mysql_dart`](https://pub.dev/packages/mysql_dart) client.
With it, a Daravel application can share a MySQL database with a Laravel
application: the framework tables, Sanctum tokens and query results match
Laravel 12's.

```bash
dart pub add daravel_mysql
```

```dart
// bootstrap/app.dart
import 'package:daravel_mysql/daravel_mysql.dart';

Application createApp() => Application.configure(basePath: '.')
    .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
    .withDatabaseDriver('mariadb', MySqlDriver.fromConfig)
    // ...
    .create();
```

```dotenv
DB_CONNECTION=mysql        # or mariadb
DB_HOST=127.0.0.1
DB_PORT=3306
DB_DATABASE=shop
DB_USERNAME=shop
DB_PASSWORD=secret
DB_SSLMODE=disable         # require / verify-full turn TLS on
DB_TIMEZONE=               # optional session time zone, as Laravel's `timezone`
```

- Tested on MySQL 8.4 (`caching_sha2_password`) and MariaDB 11 and 12.
- Values with bindings run as server-side prepared statements.
- Results read like Laravel's: `TINYINT(1)` as `0`/`1`, `DECIMAL` and
  `JSON` as strings, dates as `Y-m-d H:i:s` text.
- The session time zone is the server's unless `DB_TIMEZONE` is set, so
  `TIMESTAMP` columns read the same from Laravel and Daravel.
- Deadlocks and lock wait timeouts are retried by
  `DB.transaction(attempts: n)`.

Documentation: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/database.md>.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC; MySQL is a trademark of Oracle; MariaDB is a
trademark of MariaDB plc. Daravel is an independent project, not affiliated
with or endorsed by any of them.
