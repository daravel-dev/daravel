import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Opens a fresh [DatabaseManager] for one test.
typedef DatabaseOpener = DatabaseManager Function();

/// Runs [body] on SQLite in memory and, when `DARAVEL_TEST_PG` is set, on
/// PostgreSQL (tagged `integration`, as CI's PostgreSQL job selects).
/// `daravel_mysql/test/orm_matrix_test.dart` runs the same suites on MySQL
/// and MariaDB.
void forEachDatabase(void Function(DatabaseOpener open) body) {
  group('sqlite', () => body(sqliteInMemory));
  final url = Platform.environment['DARAVEL_TEST_PG'];
  if (url != null && url.isNotEmpty) {
    group('pgsql', () => body(() => postgresFromUrl(url)), tags: 'integration');
  }
}

DatabaseManager sqliteInMemory() => DatabaseManager(
  const DatabaseConfig(
    defaultConnection: 'sqlite',
    connections: {
      'sqlite': ConnectionConfig(driver: 'sqlite', database: ':memory:'),
    },
  ),
);

/// `postgres://user:password@host:port/database`.
DatabaseManager postgresFromUrl(String url) {
  final uri = Uri.parse(url);
  final user = uri.userInfo.split(':');
  return DatabaseManager(
    DatabaseConfig(
      defaultConnection: 'pgsql',
      connections: {
        'pgsql': ConnectionConfig(
          driver: 'pgsql',
          database: uri.path.replaceFirst('/', ''),
          host: uri.host,
          port: uri.hasPort ? uri.port : 5432,
          username: user.first,
          password: user.length > 1 ? Uri.decodeComponent(user[1]) : null,
          options: const {'pool': 2, 'sslmode': 'disable'},
        ),
      },
    ),
  );
}

/// Drops [tables] (children first) so persistent databases start clean.
Future<SchemaBuilder> freshSchema(
  DatabaseManager db,
  List<String> tables,
) async {
  final schema = SchemaBuilder(await db.executor());
  for (final table in tables.reversed) {
    await schema.dropIfExists(table);
  }
  return schema;
}
