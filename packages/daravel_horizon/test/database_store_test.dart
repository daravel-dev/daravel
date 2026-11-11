import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:path/path.dart' as p;

import 'support/store_contract.dart';

/// `DARAVEL_TEST_PG=postgres://user:secret@127.0.0.1:5432/db` and
/// `DARAVEL_TEST_MYSQL=mysql://user:secret@127.0.0.1:3306/db` add the
/// PostgreSQL and MySQL runs of the contract, as the core's suites do.
final String? pgUrl = Platform.environment['DARAVEL_TEST_PG'];
final String? mysqlUrl = Platform.environment['DARAVEL_TEST_MYSQL'];

Map<String, String> mysqlEnv(String url) {
  final uri = Uri.parse(url);
  final user = uri.userInfo.split(':');
  return {
    'DB_CONNECTION': 'mysql',
    'DB_HOST': uri.host,
    'DB_PORT': '${uri.hasPort ? uri.port : 3306}',
    'DB_DATABASE': uri.pathSegments.isEmpty ? '' : uri.pathSegments.first,
    'DB_USERNAME': user.first,
    'DB_PASSWORD': user.length > 1 ? user[1] : '',
  };
}

void main() {
  final runs = <String, Map<String, String> Function()>{
    'database, SQLite file': () => {
      'DB_CONNECTION': 'sqlite',
      'DB_DATABASE': p.join(
        Directory.systemTemp.createTempSync('horizon_db_store_').path,
        'db.sqlite',
      ),
    },
    if (pgUrl != null && pgUrl!.isNotEmpty)
      'database, PostgreSQL': () => {
        'DB_CONNECTION': 'pgsql',
        'DB_URL': pgUrl!,
      },
    if (mysqlUrl != null && mysqlUrl!.isNotEmpty)
      'database, MySQL': () => mysqlEnv(mysqlUrl!),
  };

  for (final MapEntry(key: name, value: env) in runs.entries) {
    late Application app;
    horizonStoreContract(
      name,
      () async {
        app = Application.configure(basePath: Directory.systemTemp.path)
            .withEnv({'APP_ENV': 'testing', ...env()})
            .withLogLevel(LogLevel.critical)
            .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
            .create();
        await app.boot();
        await app.run(() async {
          // A fresh set of tables each time, on a shared server too.
          final schema = await Schema.builder();
          await const CreateHorizonTables().down(schema);
          await const CreateHorizonTables().up(schema);
        });
        final store = DatabaseHorizonStore(
          app.container.make<DatabaseManager>(),
        );
        return (
          store: store as HorizonStore,
          setNow: (DateTime at) => Clock.travelTo(at),
          settle: store.flush,
        );
      },
      tearDownStore: () async {
        Clock.restore();
        await app.run(
          () async => const CreateHorizonTables().down(await Schema.builder()),
        );
        await app.shutdown();
      },
    );
  }
}
