import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class CreateNotes extends Migration {
  const CreateNotes();

  @override
  String get name => '2026_01_01_000000_create_notes';

  @override
  Future<void> up(SchemaBuilder schema) => schema.create('notes', (t) {
    t.id();
    t.string('text');
  });

  @override
  Future<void> down(SchemaBuilder schema) => schema.dropIfExists('notes');
}

const String _model = '''
import 'package:daravel/daravel.dart';

final class Note extends Model {
  static final ModelDefinition<Note> definition = ModelDefinition<Note>(
    table: 'notes',
    factory: Note.new,
  );

  @override
  ModelDefinition<Note> get modelDefinition => Note.definition;

  // <dartisan:accessors>
  // </dartisan:accessors>
}
''';

/// `model:sync --check` writes nothing and exits 1 while a model is out of
/// date with the schema, as `request:sync --check` does: a CI gate.
void main() {
  late Directory root;
  late File model;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dartisan_model_sync_check');
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');
    Directory(p.join(root.path, 'bootstrap')).createSync();
    model = File(p.join(root.path, 'lib', 'app', 'models', 'note.dart'))
      ..createSync(recursive: true)
      ..writeAsStringSync(_model);
  });
  tearDown(() => root.deleteSync(recursive: true));

  Application createApp() => Application.configure(basePath: root.path)
      .withEnv({
        'APP_ENV': 'testing',
        'DB_DATABASE': p.join(root.path, 'database.sqlite'),
      })
      .withMigrations(const [CreateNotes()])
      .create();

  Future<int> run(List<String> args) async {
    final runner = CommandRunner<int>('dartisan', 'test')
      ..addCommand(MigrateCommand(createApp))
      ..addCommand(ModelSyncCommand(createApp));
    return await IOOverrides.runZoned<Future<int?>>(
          () => runner.run(args),
          getCurrentDirectory: () => root,
        ) ??
        0;
  }

  test('--check fails while out of date and writes nothing', () async {
    expect(await run(['migrate']), 0);
    expect(await run(['model:sync', '--boot', '--check']), 1);
    expect(model.readAsStringSync(), _model, reason: 'nothing written');
    expect(await run(['model:sync', '--boot']), 0);
    expect(model.readAsStringSync(), contains('String get text'));
    expect(await run(['model:sync', '--boot', '--check']), 0);
  });
}
