/// Laravel-compatible sessions for Daravel: the `sessions` table and file
/// format, encrypted cookies and CSRF protection, so a Laravel application
/// and a Daravel application with the same `APP_KEY` and store share a
/// visitor's session.
///
/// ```dart
/// Application.configure(basePath: '.')
///     .withSession()
///     .withMigrations(const [CreateSessionsTable()])
///     .withRouting(web: (r) => r.group((r) {...}, middleware: ['web']))
/// ```
library;

export 'src/config.dart';
export 'src/guard.dart';
export 'src/handlers.dart';
export 'src/manager.dart';
export 'src/middleware.dart';
export 'src/migration.dart';
export 'src/session.dart';
export 'src/setup.dart';
