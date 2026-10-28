import 'package:daravel/daravel.dart';

/// Users, classrooms with their students, and the meetings (lessons) held
/// in them.
final class CreateClassroomTables extends Migration {
  const CreateClassroomTables();

  @override
  String get name => '2026_10_28_000001_create_classroom_tables';

  @override
  Future<void> up(SchemaBuilder schema) async {
    await schema.create('users', (table) {
      table.id();
      table.string('name');
      table.string('email').unique();
      table.string('password');
      table.timestamps();
    });
    await schema.create('classrooms', (table) {
      table.id();
      table.string('name');
      table.foreignId('teacher_id').constrained('users');
      table.timestamps();
    });
    await schema.create('classroom_student', (table) {
      table.foreignId('classroom_id').constrained().cascadeOnDelete();
      table.foreignId('user_id').constrained('users').cascadeOnDelete();
      table.primary(['classroom_id', 'user_id']);
    });
    await schema.create('meetings', (table) {
      table.id();
      table.uuid('uuid').unique();
      table.foreignId('classroom_id').constrained().cascadeOnDelete();
      table.foreignId('created_by').constrained('users');
      table.string('name');
      table.text('description').nullable();
      table.dateTime('starts_at');
      table.dateTime('ends_at');
      table.string('room_name').unique();
      table.unsignedInteger('max_participants').defaultTo(50);
      table.string('status').defaultTo('draft');
      table.string('calendar_event_id').nullable();
      table.timestamps();
      table.index(['classroom_id', 'starts_at']);
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    for (final table in [
      'meetings',
      'classroom_student',
      'classrooms',
      'users',
    ]) {
      await schema.dropIfExists(table);
    }
  }
}
