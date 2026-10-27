import 'package:daravel/daravel.dart';
import 'package:daravel_permission/daravel_permission.dart';

/// Serves an application whose `/admin` needs the `admin` role.
Application createApp() => Application.configure(basePath: '.')
    .withPermissions()
    .withMigrations(const [CreatePermissionTables()])
    .withRouting(
      api: (router) => router.get('/admin', (_) => {'ok': true}).middleware(
        const ['auth', 'role:admin'],
      ),
    )
    .create();

Future<void> main() async => Application.serveWith(createApp);
