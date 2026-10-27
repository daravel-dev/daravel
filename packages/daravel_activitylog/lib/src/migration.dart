import 'package:daravel/daravel.dart';

import 'activity_log.dart';

/// spatie/laravel-activitylog v4's `activity_log` table: its three
/// migrations (`create_activity_log_table`, `add_event_column`,
/// `add_batch_uuid_column`) in one, with Spatie's column order and index
/// names, in the table of `ACTIVITY_LOGGER_TABLE_NAME`.
///
/// It creates nothing when the table exists: a Laravel application that
/// ran Spatie's migrations owns it.
final class CreateActivityLogTable extends Migration {
  const CreateActivityLogTable();

  @override
  String get name => '2026_10_28_000000_create_activity_log_table';

  @override
  Future<void> up(SchemaBuilder schema) async {
    final table = ActivityLog.config.tableName;
    if (await schema.hasTable(table)) {
      return;
    }
    await schema.create(table, (table) {
      table.id();
      table.string('log_name').nullable();
      table.text('description');
      // nullableMorphs('subject', 'subject'), with `event` after
      // subject_type as Spatie's add_event_column puts it.
      table.string('subject_type').nullable();
      table.string('event').nullable();
      table.unsignedBigInteger('subject_id').nullable();
      table.index(['subject_type', 'subject_id'], name: 'subject');
      table.string('causer_type').nullable();
      table.unsignedBigInteger('causer_id').nullable();
      table.index(['causer_type', 'causer_id'], name: 'causer');
      table.json('properties').nullable();
      table.uuid('batch_uuid').nullable();
      table.timestamps();
      table.index(['log_name']);
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) =>
      schema.dropIfExists(ActivityLog.config.tableName);
}
