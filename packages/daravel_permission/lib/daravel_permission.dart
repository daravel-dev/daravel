/// Roles and permissions in the database for Daravel (Blueprint #36), on
/// spatie/laravel-permission's tables, so a Laravel application can share
/// them.
///
/// ```dart
/// Application.configure(basePath: '.').withPermissions()
/// ```
library;

export 'src/commands.dart';
export 'src/config.dart';
export 'src/exceptions.dart';
export 'src/has_roles.dart';
export 'src/middleware.dart';
export 'src/migration.dart';
export 'src/models.dart';
export 'src/registrar.dart';
export 'src/setup.dart';
export 'src/wildcard.dart';
