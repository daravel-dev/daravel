import 'package:daravel/daravel.dart';
import 'package:daravel_sqlite/daravel_sqlite.dart';

/// Serves an application on SQLite (`DB_CONNECTION` and `DB_*` in
/// `.env`).
Application createApp() =>
    Application.configure(basePath: '.')
        .withSqlite()
        .withRouting(
          api: (router) => router.get(
            '/tables',
            (_) async => {'tables': await (await Schema.builder()).getTables()},
          ),
        )
        .create();

Future<void> main() async => Application.serveWith(createApp);
