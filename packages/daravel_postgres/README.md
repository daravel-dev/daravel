<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_postgres

PostgreSQL driver for [Daravel](https://pub.dev/packages/daravel).

```bash
dart pub add daravel_postgres       # or: dart run bin/dartisan.dart db:install pgsql
```

```dart
// bootstrap/app.dart
import 'package:daravel_postgres/daravel_postgres.dart';

Application createApp() => Application.configure(basePath: '.')
    .withPostgres()
    // ...
    .create();
```

```dotenv
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_PORT=5432
DB_DATABASE=app
DB_USERNAME=app
DB_PASSWORD=secret
DB_SSLMODE=disable         # require / verify-full turn TLS on
DB_POOL_SIZE=10
```

## Why a package for a driver Daravel already has

Through Daravel 1.x, the PostgreSQL driver is built into `package:daravel`.
This package re-exports it, so adding it changes nothing at runtime.
`package:daravel_mysql` already works this way for MySQL and MariaDB.

In Daravel 2.0 the core no longer depends on any database client, and the
driver lives only here. Projects that depend on `daravel_postgres` and call
`.withPostgres()` keep working without changes. They also no longer
build or ship the clients of databases they do not use.

Documentation: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/database.md>.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC; PostgreSQL is a trademark of the PostgreSQL Community Association of Canada. Daravel is an independent
project, not affiliated with or endorsed by any of them.
