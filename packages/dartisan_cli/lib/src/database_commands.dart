import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;

import '../dartisan_cli.dart';

/// `dartisan db:seed [--class=Name] [--all]` — runs database seeders.
final class DbSeedCommand extends DaravelCommand {
  DbSeedCommand(super.createApp) {
    argParser
      ..addOption(
        'class',
        help:
            'Seeder class name to run (default: the first registered seeder).',
      )
      ..addFlag(
        'all',
        negatable: false,
        help: 'Run every registered seeder in order.',
      );
    addForceFlag(argParser);
  }

  @override
  String get name => 'db:seed';

  @override
  String get description => 'Seed the database with records.';

  @override
  Future<int> run() => withApp((app) async {
    final results = argResults!;
    if (refuseInProduction(app, results, name)) {
      return 1;
    }
    final registry = App.make<SeederRegistry>();
    if (registry.seeders.isEmpty) {
      stdout.writeln(
        'No seeders registered (use ApplicationBuilder.withSeeders).',
      );
      return 0;
    }
    final ran = await registry.run(
      name: results['class'] as String?,
      all: results['all'] as bool,
    );
    for (final seeder in ran) {
      stdout.writeln('Seeded: $seeder');
    }
    return 0;
  });
}

/// `dartisan migrate:fresh [--seed]` — drops all tables and migrates.
final class MigrateFreshCommand extends DaravelCommand {
  MigrateFreshCommand(super.createApp) {
    argParser
      ..addFlag(
        'seed',
        negatable: false,
        help: 'Run the root seeder afterwards.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Required when APP_ENV=production.',
      );
  }

  @override
  String get name => 'migrate:fresh';

  @override
  String get description => 'Drop all tables and re-run all migrations.';

  @override
  Future<int> run() => withApp((app) async {
    final results = argResults!;
    if (app.config.section<AppConfig>().isProduction &&
        !(results['force'] as bool)) {
      stderr.writeln(
        'migrate:fresh is destructive; pass --force to run it in production.',
      );
      return 1;
    }
    final migrated = await App.make<Migrator>().fresh();
    stdout.writeln('Dropped all tables successfully.');
    for (final name in migrated) {
      stdout.writeln('Migrated: $name');
    }
    if (results['seed'] as bool) {
      for (final seeder in await App.make<SeederRegistry>().run()) {
        stdout.writeln('Seeded: $seeder');
      }
    }
    return 0;
  });
}

/// Rows for `db:show`: every table with its column and row counts.
Future<List<List<String>>> describeDatabase(DatabaseManager db) async {
  final schema = SchemaBuilder(await db.executor());
  final rows = <List<String>>[
    ['Table', 'Columns', 'Rows'],
  ];
  for (final table in (await schema.getTables())..sort()) {
    final columns = await schema.getColumns(table);
    final count = await db.table(table).count();
    rows.add([table, '${columns.length}', '$count']);
  }
  return rows;
}

/// Rows for `db:table`: the columns of [table], or `null` when it does not
/// exist.
Future<List<List<String>>?> describeTable(
  DatabaseManager db,
  String table,
) async {
  final schema = SchemaBuilder(await db.executor());
  if (!await schema.hasTable(table) && !await schema.hasView(table)) {
    return null;
  }
  return [
    ['Column', 'Type', 'Nullable', 'Default', 'Key'],
    for (final column in await schema.getColumns(table))
      [
        column.name,
        column.type,
        column.nullable ? 'yes' : 'no',
        column.defaultValue ?? '',
        [
          if (column.primary) 'primary',
          if (column.autoIncrement) 'auto increment',
        ].join(', '),
      ],
  ];
}

/// `db:show` — lists the tables of the default connection.
final class DbShowCommand extends DaravelCommand {
  DbShowCommand(super.createApp);

  @override
  String get name => 'db:show';

  @override
  String get description => 'List the tables of the database.';

  @override
  Future<int> run() => withApp((app) async {
    final config = app.config.section<DatabaseConfig>();
    final connection = config.connections[config.defaultConnection];
    stdout
      ..writeln(
        'Connection ${config.defaultConnection} '
        '(${connection?.driver}, ${connection?.database})',
      )
      ..write(renderTable(await describeDatabase(DB.manager)));
    return 0;
  });
}

/// `db:table <table> [--limit=N]` — shows the columns of a table and,
/// with `--limit`, its first rows.
final class DbTableCommand extends DaravelCommand {
  DbTableCommand(super.createApp) {
    argParser.addOption(
      'limit',
      defaultsTo: '0',
      help: 'Also print this many rows.',
    );
  }

  @override
  String get name => 'db:table';

  @override
  String get description => 'Show the columns (and rows) of a table.';

  @override
  String get invocation => 'dartisan db:table <table> [--limit=N]';

  @override
  Future<int> run() => withApp((app) async {
    final args = argResults!;
    if (args.rest.length != 1) {
      usageException('Pass the table name.');
    }
    final table = args.rest.single;
    final columns = await describeTable(DB.manager, table);
    if (columns == null) {
      stderr.writeln('Table [$table] does not exist.');
      return 1;
    }
    stdout.write(renderTable(columns));
    final limit = int.tryParse(args['limit'] as String) ?? 0;
    if (limit > 0) {
      final rows = await DB.table(table).limit(limit).get();
      if (rows.isNotEmpty) {
        final names = rows.first.keys.toList();
        stdout.write(
          renderTable([
            names,
            for (final row in rows) [for (final name in names) '${row[name]}'],
          ]),
        );
      }
    }
    return 0;
  });
}

/// [describeModel] plus the model's database columns (`attributes`), each
/// with its type, nullability, default, key, and whether it is fillable,
/// hidden or cast; the shape of `artisan model:show --json`.
Future<Map<String, Object?>> modelDetails(
  DatabaseManager db,
  ModelDefinition<Model> model,
) async {
  final details = describeModel(model);
  final schema = SchemaBuilder(await db.executor(model.connection));
  final columns = await schema.getColumns(model.table);
  return {
    ...details,
    'attributes': [
      for (final column in columns)
        {
          'name': column.name,
          'type': column.type,
          'nullable': column.nullable,
          'default': column.defaultValue,
          'primary': column.primary,
          'increments': column.autoIncrement,
          'fillable': model.isFillable(column.name),
          'hidden': model.hidden.contains(column.name),
          'cast': switch (model.casts[column.name]) {
            final Cast cast => castName(cast),
            null => null,
          },
        },
    ],
  };
}

/// `model:show <Model> [--json]` — a model's table, attributes and
/// relations (Laravel 11), from `bootstrap/models.dart`.
final class ModelShowCommand extends DaravelCommand {
  ModelShowCommand(super.createApp) {
    argParser.addFlag('json', negatable: false, help: 'Output JSON.');
  }

  @override
  String get name => 'model:show';

  @override
  String get description => 'Show information about a model.';

  @override
  String get invocation => 'dartisan model:show <Model> [--json]';

  @override
  Future<int> run() => withApp((app) async {
    final args = argResults!;
    if (args.rest.length != 1) {
      usageException('Pass the model name.');
    }
    final registry = App.make<ModelRegistry>();
    final model = registry.find(args.rest.single);
    if (model == null) {
      stderr.writeln(
        registry.models.isEmpty
            ? 'No models are registered: list them in bootstrap/models.dart '
                  'and pass it to withModels(...).'
            : 'Model [${args.rest.single}] is not registered. Known: '
                  '${registry.models.map(modelClassName).join(', ')}.',
      );
      return 1;
    }
    final details = await modelDetails(DB.manager, model);
    if (args['json'] as bool) {
      stdout.writeln(jsonEncode(details));
      return 0;
    }
    final attributes = details['attributes']! as List<Object?>;
    final relations = details['relations']! as List<Object?>;
    stdout
      ..writeln('${details['class']} (${details['morphClass']})')
      ..writeln(
        'Table ${details['table']}, primary key ${details['primaryKey']}'
        '${model.softDeletes ? ', soft deletes' : ''}'
        '${model.timestamps ? ', timestamps' : ''}',
      )
      ..writeln()
      ..write(
        renderTable([
          ['Attribute', 'Type', 'Cast', 'Flags'],
          for (final a in attributes.cast<Map<String, Object?>>())
            [
              '${a['name']}',
              '${a['type']}',
              '${a['cast'] ?? ''}',
              [
                if (a['primary'] == true) 'primary',
                if (a['increments'] == true) 'increments',
                if (a['nullable'] == true) 'nullable',
                if (a['fillable'] == true) 'fillable',
                if (a['hidden'] == true) 'hidden',
              ].join(', '),
            ],
        ]),
      );
    if (relations.isNotEmpty) {
      stdout
        ..writeln()
        ..write(
          renderTable([
            ['Relation', 'Type', 'Related'],
            for (final r in relations.cast<Map<String, Object?>>())
              [
                '${r['name']}',
                '${r['type']}',
                switch (r['related']) {
                  final List<Object?> types => types.join(', '),
                  final other => '$other',
                },
              ],
          ]),
        );
    }
    return 0;
  });
}

/// Copies the SQLite database behind [db] to [target] with `VACUUM INTO`:
/// a consistent copy even while the server writes (unlike copying the file,
/// which can catch a write half done), checked with `PRAGMA
/// integrity_check`. Returns the backup's size in bytes.
Future<int> backupSqlite(DatabaseManager db, String target) async {
  final file = File(target);
  if (file.existsSync()) {
    throw StateError('$target exists; backups never overwrite a file.');
  }
  file.parent.createSync(recursive: true);
  await db.statement('VACUUM INTO ?', [file.absolute.path]);
  final check = DatabaseManager(
    DatabaseConfig(
      defaultConnection: 'backup',
      connections: {
        'backup': ConnectionConfig(driver: 'sqlite', database: file.path),
      },
    ),
  );
  try {
    final result = await check.select('PRAGMA integrity_check');
    final status = result.isEmpty ? null : result.first.values.first;
    if (status != 'ok') {
      throw StateError(
        'The backup at $target failed its integrity check: '
        '$status',
      );
    }
  } finally {
    await check.closeAll();
  }
  return file.lengthSync();
}

/// Deletes all but the newest [keep] `*.sqlite` backups in [directory]
/// (names sort by their timestamp); returns the deleted paths.
List<String> pruneBackups(String directory, int keep) {
  final dir = Directory(directory);
  if (!dir.existsSync()) {
    return const [];
  }
  final backups =
      dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.sqlite'))
          .toList()
        ..sort((a, b) => b.path.compareTo(a.path));
  final removed = [for (final old in backups.skip(keep)) old.path];
  for (final path in removed) {
    File(path).deleteSync();
  }
  return removed;
}

/// `db:backup [--output] [--keep=N]`: a hot backup of the SQLite database
/// into `storage/backups/` (schedule it with
/// `schedule.command('db:backup', ['--keep=14']).dailyAt('02:00')`).
final class DbBackupCommand extends DaravelCommand {
  DbBackupCommand(super.createApp) {
    argParser
      ..addOption(
        'output',
        help: 'Backup file (default: storage/backups/<name>-<time>.sqlite).',
      )
      ..addOption(
        'keep',
        help: 'Keep only the newest N backups in the backup directory.',
      );
  }

  @override
  String get name => 'db:backup';

  @override
  String get description => 'Back up the SQLite database while it is in use.';

  @override
  Future<int> run() => withApp((app) async {
    final config = app.config.section<DatabaseConfig>();
    final connection = config.connections[config.defaultConnection];
    switch (connection?.driver) {
      case 'sqlite':
        break;
      case 'pgsql':
        stderr.writeln(
          'db:backup copies SQLite databases. For PostgreSQL use pg_dump, '
          'e.g. pg_dump --format=custom --file=backup.dump '
          '"${connection!.database}" (PGPASSWORD in the environment).',
        );
        return 1;
      case 'mysql' || 'mariadb':
        stderr.writeln(
          'db:backup copies SQLite databases. For MySQL and MariaDB use '
          'mysqldump --single-transaction "${connection!.database}" '
          '(MYSQL_PWD in the environment).',
        );
        return 1;
      default:
        stderr.writeln('No SQLite connection [${config.defaultConnection}].');
        return 1;
    }
    final database = connection!.database;
    if (database == ':memory:' || database.startsWith('file:')) {
      stderr.writeln('An in-memory database has nothing to back up.');
      return 1;
    }
    final args = argResults!;
    final directory = p.join(app.basePath, 'storage', 'backups');
    String two(int n) => n.toString().padLeft(2, '0');
    final now = DateTime.now().toUtc();
    final stamp =
        '${now.year}-${two(now.month)}-${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
    final target =
        args['output'] as String? ??
        p.join(
          directory,
          '${p.basenameWithoutExtension(database)}-$stamp.sqlite',
        );
    final int size;
    try {
      size = await backupSqlite(DB.manager, target);
    } on StateError catch (error) {
      stderr.writeln(error.message);
      return 1;
    }
    stdout.writeln(
      'Backed up to ${p.relative(target, from: app.basePath)} '
      '(${(size / 1024).toStringAsFixed(1)} KB).',
    );
    final keep = int.tryParse(args['keep'] as String? ?? '');
    if (keep != null && keep > 0) {
      for (final path in pruneBackups(p.dirname(target), keep)) {
        stdout.writeln('Removed ${p.relative(path, from: app.basePath)}');
      }
    }
    return 0;
  });
}
