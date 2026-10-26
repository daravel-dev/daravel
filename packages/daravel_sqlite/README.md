<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_sqlite

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_sqlite/README.id.md)

SQLite driver for [Daravel](https://pub.dev/packages/daravel).

```bash
dart pub add daravel_sqlite       # or: dart run bin/dartisan.dart db:install sqlite
```

```dart
// bootstrap/app.dart
import 'package:daravel_sqlite/daravel_sqlite.dart';

Application createApp() => Application.configure(basePath: '.')
    .withSqlite()
    // ...
    .create();
```

```dotenv
DB_CONNECTION=sqlite
DB_DATABASE=database/database.sqlite   # or :memory: for tests
```

## Why a package for a driver Daravel already has

Through Daravel 1.x, the SQLite driver is built into `package:daravel`.
This package re-exports it, so adding it changes nothing at runtime.
`package:daravel_mysql` already works this way for MySQL and MariaDB.

In Daravel 2.0 the core no longer depends on any database client, and the
driver lives only here. Projects that depend on `daravel_sqlite` and call
`.withSqlite()` keep working without changes. They also no longer
build or ship the clients of databases they do not use.

Documentation: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/database.md>.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC; SQLite is in the public domain. Daravel is an independent
project, not affiliated with or endorsed by any of them.
