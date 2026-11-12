import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:dartisan_cli/src/region_format.dart';
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

/// A model whose accessors region holds a line that does not compile, as
/// after a sync whose output the application no longer accepts (#329).
const String _broken = '''
import 'package:daravel/daravel.dart';

final class Note extends Model {
  static final ModelDefinition<Note> definition = ModelDefinition<Note>(
    table: 'notes',
    factory: Note.new,
  );

  @override
  ModelDefinition<Note> get modelDefinition => Note.definition;

  // <dartisan:statics>
  static ModelQuery<Note> query() => definition.query();
  // </dartisan:statics>

  // <dartisan:accessors>
  int get text => 'not an int';
  // </dartisan:accessors>
}

// <dartisan:relation-path>
extension NoteRelationPath<Root extends Model> on RelationToken<Root, Note> {}
// </dartisan:relation-path>
''';

/// model:sync without compiling the application (#329).
void main() {
  group('the program model:sync writes', () {
    test('imports the registry, else daravel_mysql, else nothing', () {
      final registry = modelSyncEntrySource(registry: true, mysql: true);
      expect(registry, contains("import '../../bootstrap/database.dart';"));
      expect(registry, contains('drivers: databaseDrivers,'));
      expect(registry, isNot(contains('daravel_mysql')));
      final mysql = modelSyncEntrySource(registry: false, mysql: true);
      expect(mysql, contains('package:daravel_mysql/daravel_mysql.dart'));
      expect(mysql, contains("'mariadb': MySqlDriver.fromConfig,"));
      final none = modelSyncEntrySource(registry: false, mysql: false);
      expect(none, isNot(contains('mysql')));
      expect(none, isNot(contains('bootstrap')));
      // Never anything from the application, nor a value of its env.
      for (final source in [registry, mysql, none]) {
        expect(source, isNot(contains('app.dart')));
        expect(source, isNot(contains('lib/app')));
        expect(source, isNot(contains('DB_')));
      }
    });

    test('learns the drivers from bootstrap/database.dart or pubspec', () {
      final root = Directory.systemTemp.createTempSync('model_sync_drivers');
      addTearDown(() => root.deleteSync(recursive: true));
      final pubspec = File(p.join(root.path, 'pubspec.yaml'))
        ..writeAsStringSync('name: shop\ndependencies:\n  daravel: any\n');
      expect(projectDrivers(root.path), (registry: false, mysql: false));
      pubspec.writeAsStringSync(
        'name: shop\ndependencies:\n  daravel: any\n  daravel_mysql: any\n',
      );
      expect(projectDrivers(root.path), (registry: false, mysql: true));
      File(p.join(root.path, 'bootstrap', 'database.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync('');
      expect(projectDrivers(root.path), (registry: true, mysql: true));
    });
  });

  group('in a project', () {
    late Directory root;
    late File model;

    setUp(() async {
      root = Directory.systemTemp.createTempSync('model_sync_entry');
      File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: x\n');
      Directory(p.join(root.path, 'bootstrap')).createSync();
      final database = p.join(root.path, 'database.sqlite');
      File(p.join(root.path, '.env')).writeAsStringSync(
        'APP_ENV=testing\nDB_CONNECTION=sqlite\nDB_DATABASE=$database\n',
      );
      model = File(p.join(root.path, 'lib', 'app', 'models', 'note.dart'))
        ..createSync(recursive: true)
        ..writeAsStringSync(_broken);
      final app = Application.configure(basePath: root.path)
          .withLogLevel(LogLevel.critical)
          .withMigrations(const [CreateNotes()])
          .create();
      await app.boot();
      await app.run(() => App.make<Migrator>().run());
      await app.shutdown();
    });
    tearDown(() => root.deleteSync(recursive: true));

    Future<T> inProject<T>(Future<T> Function() body) =>
        IOOverrides.runZoned(body, getCurrentDirectory: () => root);

    test('the program syncs a model whose generated code is broken, from the '
        'environment alone', () async {
      // What the program runs: no application code, only .env and the
      // drivers.
      expect(await inProject(() => runModelSyncEntry(const [])), 0);
      final synced = model.readAsStringSync();
      expect(synced, contains('String get text'));
      expect(synced, isNot(contains("'not an int'")));
      // Synced once more: up to date, nothing to write.
      expect(await inProject(() => runModelSyncEntry(const ['--check'])), 0);
    });

    test('--reset-regions empties the generated regions, never statics; '
        '--dry-run writes nothing', () async {
      Future<int?> run(List<String> args) => inProject(
        () =>
            (CommandRunner<int>(
                  'dartisan',
                  'test',
                )..addCommand(ModelSyncCommand(() => throw StateError('none'))))
                .run(['model:sync', '--reset-regions', ...args]),
      );
      expect(await run(['--dry-run']), 0);
      expect(model.readAsStringSync(), _broken, reason: 'dry run');
      expect(await run(const []), 0);
      final reset = model.readAsStringSync();
      expect(reset, isNot(contains("'not an int'")));
      expect(reset, isNot(contains('NoteRelationPath')));
      expect(reset, contains('static ModelQuery<Note> query()'));
      expect(
        reset,
        contains('// <dartisan:accessors>\n  // </dartisan:accessors>'),
      );
      expect(
        resetModelRegions(Directory(p.join(root.path, 'lib', 'app', 'models'))),
        isEmpty,
        reason: 'already empty',
      );
    });

    test('a compile error in a generated region is named', () {
      final output = [
        'lib/app/models/note.dart:16:26: Error: A value of type ...',
        'lib/app/models/note.dart:3:1: Error: outside any region',
        'lib/app/other.dart:1:1: Error: no such file here',
      ].join('\n');
      expect(errorsInGeneratedRegions(output, root.path), [
        '${p.join('lib', 'app', 'models', 'note.dart')}:16 (accessors)',
      ]);
    });
  });

  test('a second sync of unchanged code is up to date, long lines '
      'included (#329 b)', () {
    const name = 'SubscriptionBillingAddressHistoryEntryRecord';
    const source =
        '''
import 'package:daravel/daravel.dart';

final class $name extends Model {
  static final ModelDefinition<$name> definition = ModelDefinition<$name>(
    table: 'subscription_billing_address_history_entry_records',
    factory: $name.new,
  );

  @override
  ModelDefinition<$name> get modelDefinition => $name.definition;

  // <dartisan:accessors>
  // </dartisan:accessors>
}
''';
    const columns = [
      ColumnInfo(name: 'id', type: 'INTEGER', nullable: false, primary: true),
      ColumnInfo(
        name: 'previous_subscription_billing_address_line_two',
        type: 'VARCHAR',
        nullable: true,
      ),
    ];
    String sync(String text) => syncModelSource(
      text,
      ModelSource.parse(text)!,
      columns,
      formatter: RegionFormatter(),
    ).source!;
    final once = sync(source);
    // The code model:sync writes fits 80 columns (dart format leaves the
    // long doc comments as they are, as it does everywhere).
    final region = once.substring(
      once.indexOf('// <dartisan:accessors>'),
      once.indexOf('// </dartisan:accessors>'),
    );
    expect(
      region
          .split('\n')
          .where((l) => l.length > 80 && !l.trimLeft().startsWith('//')),
      isEmpty,
    );
    expect(sync(once), once);
  });
}
