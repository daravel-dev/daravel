import 'package:daravel/daravel.dart';

/// Creates the exam_sessions table.
final class CreateExamSessionsTable extends Migration {
  const CreateExamSessionsTable();

  @override
  String get name => '2026_11_01_000003_create_exam_sessions_table';

  @override
  Future<void> up(SchemaBuilder schema) =>
      schema.create('exam_sessions', (table) {
        table.string('id', length: 64).primary();
        table.foreignId('candidate_id').constrained('candidates');
        table.string('device_id');
        table.string('token', length: 128).unique();
        table.timestamp('started_at');
        table.integer('duration_minutes').defaultTo(30);
        table.timestamp('expires_at');
        table.timestamp('submitted_at').nullable();
        table.string('status', length: 32).defaultTo('active');
        table.integer('score_twk').nullable();
        table.integer('score_tiu').nullable();
        table.integer('score_tkp').nullable();
        table.integer('total_score').nullable();
        table.boolean('passing_grade_met').nullable();
        table.integer('ranking').nullable();
        table.integer('seed').defaultTo(42);
        table.timestamps();
      });

  @override
  Future<void> down(SchemaBuilder schema) =>
      schema.dropIfExists('exam_sessions');
}
