import 'package:daravel/daravel.dart';

/// Creates the exam_answers table.
final class CreateExamAnswersTable extends Migration {
  const CreateExamAnswersTable();

  @override
  String get name => '2026_11_01_000004_create_exam_answers_table';

  @override
  Future<void> up(SchemaBuilder schema) =>
      schema.create('exam_answers', (table) {
        table.id();
        table.string('session_id', length: 64);
        table.foreignId('candidate_id').constrained('candidates');
        table.foreignId('question_id').constrained('questions');
        table.string('selected_option', length: 8);
        table.boolean('is_doubtful').defaultTo(false);
        table.string('idempotency_key', length: 128);
        table.timestamp('answered_at');
        table.timestamps();

        table.unique(['session_id', 'question_id']);
        table.index(['session_id']);
      });

  @override
  Future<void> down(SchemaBuilder schema) =>
      schema.dropIfExists('exam_answers');
}
