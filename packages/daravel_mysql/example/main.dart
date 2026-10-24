import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';

/// Serves an application on MySQL (`DB_CONNECTION=mysql` and `DB_*` in
/// `.env`).
Application createApp() =>
    Application.configure(basePath: '.')
        .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
        .withDatabaseDriver('mariadb', MySqlDriver.fromConfig)
        .withRouting(
          api: (router) => router.get(
            '/tables',
            (_) async => {'tables': await (await Schema.builder()).getTables()},
          ),
        )
        .create();

Future<void> main() async => Application.serveWith(createApp);
