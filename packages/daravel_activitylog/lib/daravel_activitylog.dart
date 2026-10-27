/// An activity log for Daravel (Blueprint #38) on spatie/laravel-activitylog
/// v4's `activity_log` table, so a Laravel application can share it:
/// model changes with their old values, activities logged by hand, causers,
/// batches.
///
/// ```dart
/// Application.configure(basePath: '.').withActivityLog()
/// ```
library;

export 'src/activity.dart';
export 'src/activity_log.dart' hide encodeProperties;
export 'src/config.dart';
export 'src/log_options.dart';
export 'src/logs_activity.dart';
export 'src/migration.dart';
export 'src/setup.dart';
