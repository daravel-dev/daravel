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

final class NoteSeeder extends Seeder {
  const NoteSeeder();

  @override
  Future<void> run() => DB.table('notes').insert({'text': 'seeded'});
}

/// `migrate --seed` runs the root seeder after migrating, as `migrate:fresh
/// --seed` does; the flag used to be declared and never read.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dartisan_migrate_seed');
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');
    Directory(p.join(root.path, 'bootstrap')).createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Application createApp() => Application.configure(basePath: root.path)
      .withEnv({
        'APP_ENV': 'testing',
        'DB_DATABASE': p.join(root.path, 'database.sqlite'),
      })
      .withMigrations(const [CreateNotes()])
      .withSeeders(const [NoteSeeder()])
      .create();

  Future<int> run(List<String> args) async {
    final runner = CommandRunner<int>('dartisan', 'test')
      ..addCommand(MigrateCommand(createApp));
    return await IOOverrides.runZoned<Future<int?>>(
          () => runner.run(args),
          getCurrentDirectory: () => root,
        ) ??
        0;
  }

  Future<int> notes() async {
    final app = createApp();
    await app.boot();
    try {
      return await app.run(() => DB.table('notes').count());
    } finally {
      await app.shutdown();
    }
  }

  test('migrate --seed seeds; migrate alone does not', () async {
    expect(await run(['migrate']), 0);
    expect(await notes(), 0);
    expect(await run(['migrate', '--seed']), 0);
    expect(await notes(), 1, reason: 'nothing to migrate, still seeded');
  });
}
