import 'dart:io';

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

/// Destructive commands refuse to run under `APP_ENV=production` without
/// `--force`, as artisan's do; and a framework error is a message and exit
/// 1, not a stack trace and the VM's 255.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dartisan_guards');
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');
    Directory(p.join(root.path, 'bootstrap')).createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  Application app({String env = 'production'}) =>
      Application.configure(basePath: root.path)
          .withEnv({
            'APP_ENV': env,
            'APP_KEY': 'base64:${'A' * 43}=',
            'DB_DATABASE': p.join(root.path, 'database.sqlite'),
          })
          .withLogLevel(LogLevel.critical)
          .withMigrations(const [CreateNotes()])
          .withSeeders(const [NoteSeeder()])
          .create();

  Future<int> run(List<String> args, {String env = 'production'}) =>
      IOOverrides.runZoned(
        () => DartisanRunner(() => app(env: env)).execute(args),
        getCurrentDirectory: () => root,
      );

  test('rollback, reset and db:seed need --force in production', () async {
    expect(await run(['migrate']), 0);
    for (final command in ['migrate:rollback', 'migrate:reset', 'db:seed']) {
      expect(await run([command]), 1, reason: command);
    }
    // Outside production nothing changes (seeded first: a rollback drops
    // the table).
    for (final command in ['db:seed', 'migrate:rollback', 'migrate:reset']) {
      expect(await run([command], env: 'local'), 0, reason: command);
    }
    expect(await run(['migrate']), 0);
    expect(await run(['db:seed', '--force']), 0);
    expect(await run(['migrate:rollback', '--force']), 0);
    expect(await run(['migrate:reset', '--force']), 0);
  });

  test('a framework error is one line and exit 1, not 255', () async {
    final broken = Application.configure(basePath: root.path)
        .withEnv({'APP_ENV': 'local', 'DB_CONNECTION': 'nope'})
        .withLogLevel(LogLevel.critical)
        .create();
    final code = await IOOverrides.runZoned(
      () => DartisanRunner(() => broken).execute(['migrate']),
      getCurrentDirectory: () => root,
    );
    expect(code, 1);
  });
}
