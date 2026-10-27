import 'package:daravel/daravel.dart';

/// `config/activitylog.php` (spatie/laravel-activitylog v4), with its
/// environment variables.
final class ActivityLogConfig implements ConfigSection {
  const ActivityLogConfig({
    this.enabled = true,
    this.tableName = 'activity_log',
    this.connection,
    this.defaultLogName = 'default',
    this.deleteRecordsOlderThanDays = 365,
    this.authGuard,
    this.subjectReturnsSoftDeletedModels = false,
  });

  factory ActivityLogConfig.fromEnv(Env env) {
    String? optional(String key) {
      final value = env.maybeString(key);
      return value == null || value.isEmpty ? null : value;
    }

    return ActivityLogConfig(
      enabled: env.boolean('ACTIVITY_LOGGER_ENABLED', true),
      tableName: env.string('ACTIVITY_LOGGER_TABLE_NAME', 'activity_log'),
      connection: optional('ACTIVITY_LOGGER_DB_CONNECTION'),
      defaultLogName: env.string('ACTIVITY_LOGGER_DEFAULT_LOG_NAME', 'default'),
      deleteRecordsOlderThanDays: env.integer(
        'ACTIVITY_LOGGER_DELETE_RECORDS_OLDER_THAN_DAYS',
        365,
      ),
      authGuard: optional('ACTIVITY_LOGGER_AUTH_GUARD'),
      subjectReturnsSoftDeletedModels: env.boolean(
        'ACTIVITY_LOGGER_SUBJECT_RETURNS_SOFT_DELETED_MODELS',
        false,
      ),
    );
  }

  /// When false, nothing is written (`ACTIVITY_LOGGER_ENABLED`).
  final bool enabled;

  /// `ACTIVITY_LOGGER_TABLE_NAME`, `activity_log` by default.
  final String tableName;

  /// The database connection of the table (`ACTIVITY_LOGGER_DB_CONNECTION`);
  /// the default connection when null.
  final String? connection;

  /// The `log_name` of activities that do not choose one.
  final String defaultLogName;

  /// What `activitylog:clean` deletes without `--days`.
  final int deleteRecordsOlderThanDays;

  /// The guard whose user causes activities (Spatie's
  /// `default_auth_driver`); the request's active guard when null.
  final String? authGuard;

  /// Whether `Activity.subject()` finds soft-deleted subjects.
  final bool subjectReturnsSoftDeletedModels;

  @override
  String get key => 'activitylog';

  @override
  Map<String, Object?> toMap() => {
    'enabled': enabled,
    'table_name': tableName,
    'database_connection': connection,
    'default_log_name': defaultLogName,
    'delete_records_older_than_days': deleteRecordsOlderThanDays,
    'default_auth_driver': authGuard,
    'subject_returns_soft_deleted_models': subjectReturnsSoftDeletedModels,
  };
}
