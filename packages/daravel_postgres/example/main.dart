import 'package:daravel/daravel.dart';
import 'package:daravel_postgres/daravel_postgres.dart';

/// Serves an application on PostgreSQL (`DB_CONNECTION` and `DB_*` in
/// `.env`).
Application createApp() =>
    Application.configure(basePath: '.')
        .withPostgres()
        .withRouting(
          api: (router) => router.get(
            '/tables',
            (_) async => {'tables': await (await Schema.builder()).getTables()},
          ),
        )
        .create();

Future<void> main() async => Application.serveWith(createApp);
