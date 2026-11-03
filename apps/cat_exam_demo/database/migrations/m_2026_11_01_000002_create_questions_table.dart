import 'package:daravel/daravel.dart';

/// Creates the questions table.
final class CreateQuestionsTable extends Migration {
  const CreateQuestionsTable();

  @override
  String get name => '2026_11_01_000002_create_questions_table';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('questions', (table) {
    table.id();
    table.string('category', length: 16);
    table.text('question_text');
    table.json('options');
    table.string('correct_option', length: 8).nullable();
    table.integer('weight').defaultTo(5);
    table.timestamps();
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('questions');
}
