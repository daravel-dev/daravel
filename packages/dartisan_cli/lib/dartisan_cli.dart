/// `dartisan` command runner and built-in commands (BLUEPRINT_V2 §8).
///
/// Tier 0 ships the project-bound runner: an application's `bin/dartisan.dart`
/// passes its `createApp` factory to [DartisanRunner].
library;

import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';

import 'src/database_commands.dart';
import 'src/cache_commands.dart';
import 'src/make_commands.dart';
import 'src/queue_commands.dart';

export 'src/database_commands.dart';
export 'src/generator.dart';
export 'src/cache_commands.dart';
export 'src/make_commands.dart';
export 'src/queue_commands.dart';

/// Creates an unbooted [Application] (a project's `createApp()`).
typedef AppFactory = Application Function();

/// Command runner wired to a project's application factory.
final class DartisanRunner extends CommandRunner<int> {
  DartisanRunner(AppFactory createApp)
    : super('dartisan', 'Daravel command-line interface.') {
    addCommand(AboutCommand(createApp));
    addCommand(ServeCommand(createApp));
    addCommand(RouteListCommand(createApp));
    addCommand(MigrateCommand(createApp));
    addCommand(MigrateStatusCommand(createApp));
    addCommand(MigrateRollbackCommand(createApp));
    addCommand(MigrateResetCommand(createApp));
    addCommand(MigrateFreshCommand(createApp));
    addCommand(DbSeedCommand(createApp));
    addCommand(CacheClearCommand(createApp));
    addCommand(CoordinatorStatsCommand(createApp));
    addCommand(QueueWorkCommand(createApp));
    addCommand(QueueFailedCommand(createApp));
    addCommand(QueueRetryCommand(createApp));
    addCommand(QueueForgetCommand(createApp));
    addCommand(QueueFlushCommand(createApp));
    addCommand(QueueClearCommand(createApp));
    addCommand(QueueRestartCommand(createApp));
    addCommand(ScheduleRunCommand(createApp, this));
    addCommand(ScheduleWorkCommand(createApp, this));
    addCommand(ScheduleListCommand(createApp));
    addCommand(MakeJobCommand());
    addCommand(MakeModelCommand());
    addCommand(MakeMigrationCommand());
    addCommand(MakeSeederCommand());
    addCommand(MakeFactoryCommand());
    addCommand(MakeControllerCommand());
    addCommand(MakeRequestCommand());
    addCommand(MakeMiddlewareCommand());
  }

  /// Runs [command] with [args] and returns its exit code (used by the
  /// scheduler for `schedule.command(...)`).
  Future<int> runNamed(String command, List<String> args) async =>
      await run(<String>[command, ...args]) ?? 1;

  /// Runs [args] and returns a process exit code (never throws for usage
  /// errors).
  Future<int> execute(List<String> args) async {
    try {
      return await run(args) ?? 0;
    } on UsageException catch (error) {
      stderr.writeln(error);
      return 64;
    }
  }
}

/// Base class for commands that need the project application.
abstract class DaravelCommand extends Command<int> {
  DaravelCommand(this.createApp);

  final AppFactory createApp;

  /// Boots the application, runs [body] inside a `command` scope and shuts
  /// the application down afterwards.
  Future<int> withApp(FutureOr<int> Function(Application app) body) async {
    final app = createApp();
    try {
      await app.boot();
      return await app.run<int>(() => body(app));
    } finally {
      await app.shutdown();
    }
  }
}

/// `dartisan serve` — starts the HTTP server.
final class ServeCommand extends DaravelCommand {
  ServeCommand(super.createApp) {
    argParser
      ..addOption(
        'host',
        help: 'Host to bind (default: APP_HOST or 127.0.0.1).',
      )
      ..addOption('port', help: 'Port to bind (default: APP_PORT or 8000).')
      ..addOption(
        'isolates',
        help: 'HTTP worker isolates (default: APP_ISOLATES or 1).',
      );
  }

  @override
  String get name => 'serve';

  @override
  String get description => 'Serve the application over HTTP.';

  @override
  Future<int> run() async {
    final results = argResults!;
    final host = results['host'] as String?;
    final portValue = results['port'] as String?;
    final port = portValue == null ? null : int.tryParse(portValue);
    if (portValue != null && port == null) {
      usageException('--port must be an integer, got "$portValue".');
    }
    final isolatesValue = results['isolates'] as String?;
    final isolates = isolatesValue == null ? null : int.tryParse(isolatesValue);
    if (isolatesValue != null && (isolates == null || isolates < 1)) {
      usageException('--isolates must be a positive integer.');
    }
    return Application.serveWith(
      createApp,
      host: host,
      port: port,
      isolates: isolates,
    );
  }
}

/// `dartisan route:list` — prints the compiled route table.
final class RouteListCommand extends DaravelCommand {
  RouteListCommand(super.createApp);

  @override
  String get name => 'route:list';

  @override
  String get description => 'List all registered routes.';

  @override
  Future<int> run() => withApp((app) {
    final rows = <List<String>>[
      <String>['Method', 'URI', 'Name', 'Middleware'],
      for (final route in app.router.routes)
        <String>[
          route.methods.join('|'),
          route.path,
          route.routeName ?? '',
          route.middlewareEntries
              .map(
                (entry) =>
                    entry is String ? entry : entry.runtimeType.toString(),
              )
              .join(', '),
        ],
    ];
    stdout.write(renderTable(rows));
    stdout.writeln('\n${app.router.routes.length} route(s).');
    return 0;
  });
}

/// `dartisan migrate` — runs pending migrations.
final class MigrateCommand extends DaravelCommand {
  MigrateCommand(super.createApp) {
    argParser.addFlag(
      'seed',
      negatable: false,
      help: 'Run the root seeder afterwards.',
    );
  }

  @override
  String get name => 'migrate';

  @override
  String get description => 'Run the pending database migrations.';

  @override
  Future<int> run() => withApp((app) async {
    final migrated = await App.make<Migrator>().run();
    if (migrated.isEmpty) {
      stdout.writeln('Nothing to migrate.');
    } else {
      for (final name in migrated) {
        stdout.writeln('Migrated: $name');
      }
    }
    return 0;
  });
}

/// `dartisan migrate:status` — shows ran/pending migrations.
final class MigrateStatusCommand extends DaravelCommand {
  MigrateStatusCommand(super.createApp);

  @override
  String get name => 'migrate:status';

  @override
  String get description => 'Show the status of each migration.';

  @override
  Future<int> run() => withApp((app) async {
    final statuses = await App.make<Migrator>().status();
    stdout.write(
      renderTable(<List<String>>[
        <String>['Migration', 'Batch', 'Status'],
        for (final status in statuses)
          <String>[
            status.name,
            status.batch?.toString() ?? '',
            status.ran ? 'Ran' : 'Pending',
          ],
      ]),
    );
    return 0;
  });
}

/// `dartisan migrate:rollback` — rolls back the last batch(es).
final class MigrateRollbackCommand extends DaravelCommand {
  MigrateRollbackCommand(super.createApp) {
    argParser.addOption(
      'step',
      defaultsTo: '1',
      help: 'Number of batches to roll back.',
    );
  }

  @override
  String get name => 'migrate:rollback';

  @override
  String get description => 'Rollback the last database migration batch.';

  @override
  Future<int> run() => withApp((app) async {
    final stepValue = argResults!['step'] as String;
    final steps = int.tryParse(stepValue);
    if (steps == null || steps < 1) {
      usageException('--step must be a positive integer, got "$stepValue".');
    }
    final rolledBack = await App.make<Migrator>().rollback(steps: steps);
    if (rolledBack.isEmpty) {
      stdout.writeln('Nothing to rollback.');
    } else {
      for (final name in rolledBack) {
        stdout.writeln('Rolled back: $name');
      }
    }
    return 0;
  });
}

/// `dartisan migrate:reset` — rolls back every migration.
final class MigrateResetCommand extends DaravelCommand {
  MigrateResetCommand(super.createApp);

  @override
  String get name => 'migrate:reset';

  @override
  String get description => 'Rollback all database migrations.';

  @override
  Future<int> run() => withApp((app) async {
    final rolledBack = await App.make<Migrator>().reset();
    if (rolledBack.isEmpty) {
      stdout.writeln('Nothing to rollback.');
    } else {
      for (final name in rolledBack) {
        stdout.writeln('Rolled back: $name');
      }
    }
    return 0;
  });
}

/// Renders rows as an aligned ASCII table (first row = header).
String renderTable(List<List<String>> rows) {
  if (rows.isEmpty) {
    return '';
  }
  final columnCount = rows.first.length;
  final widths = List<int>.filled(columnCount, 0);
  for (final row in rows) {
    for (var i = 0; i < columnCount; i++) {
      final cell = i < row.length ? row[i] : '';
      if (cell.length > widths[i]) {
        widths[i] = cell.length;
      }
    }
  }
  final buffer = StringBuffer();
  final separator = '+${widths.map((w) => '-' * (w + 2)).join('+')}+';
  buffer.writeln(separator);
  for (var r = 0; r < rows.length; r++) {
    final row = rows[r];
    final cells = <String>[
      for (var i = 0; i < columnCount; i++)
        ' ${(i < row.length ? row[i] : '').padRight(widths[i])} ',
    ];
    buffer.writeln('|${cells.join('|')}|');
    if (r == 0) {
      buffer.writeln(separator);
    }
  }
  buffer.writeln(separator);
  return buffer.toString();
}

/// `dartisan about` — summarizes the application environment.
final class AboutCommand extends DaravelCommand {
  AboutCommand(super.createApp);

  @override
  String get name => 'about';

  @override
  String get description => 'Display basic information about your application.';

  @override
  Future<int> run() => withApp((app) async {
    final appConfig = app.config.section<AppConfig>();
    final db = app.config.section<DatabaseConfig>();
    final connection = db.connections[db.defaultConnection];
    stdout.write(
      renderTable(<List<String>>[
        <String>['Key', 'Value'],
        <String>['Application', appConfig.name],
        <String>['Environment', appConfig.env],
        <String>['Debug mode', appConfig.debug ? 'ENABLED' : 'OFF'],
        <String>['URL', appConfig.url],
        <String>['Timezone', appConfig.timezone],
        <String>['Locale', appConfig.locale],
        <String>['Dart', Platform.version.split(' ').first],
        <String>['Daravel', '0.0.1-dev (Tier 1 / S1)'],
        <String>[
          'Database',
          '${db.defaultConnection} (${connection?.driver ?? '?'})',
        ],
        <String>['Routes', '${app.router.routes.length}'],
        <String>['Migrations', '${App.make<Migrator>().migrations.length}'],
        <String>['Base path', app.basePath],
      ]),
    );
    return 0;
  });
}
