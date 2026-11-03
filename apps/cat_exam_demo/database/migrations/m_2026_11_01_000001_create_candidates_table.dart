import 'package:daravel/daravel.dart';

/// Creates the candidates table.
final class CreateCandidatesTable extends Migration {
  const CreateCandidatesTable();

  @override
  String get name => '2026_11_01_000001_create_candidates_table';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('candidates', (table) {
    table.id();
    table.string('nik', length: 32).unique();
    table.string('exam_number', length: 64).unique();
    table.string('name');
    table.string('device_id').nullable();
    table.string('active_session_id').nullable();
    table.string('status', length: 32).defaultTo('registered');
    table.timestamps();
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('candidates');
}
