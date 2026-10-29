import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;

import '../dartisan_cli.dart';

/// The SQLite file of the default connection, or `null` with a message.
String? _sqlitePath(Application app) {
  final config = app.config.section<DatabaseConfig>();
  final connection = config.connections[config.defaultConnection];
  if (connection?.driver != 'sqlite') {
    stderr.writeln(
      'Replication follows SQLite databases; [${config.defaultConnection}] '
      'is ${connection?.driver ?? 'not configured'}.',
    );
    return null;
  }
  final database = connection!.database;
  if (database == ':memory:' || database.startsWith('file:')) {
    stderr.writeln('An in-memory database cannot be replicated.');
    return null;
  }
  return p.isAbsolute(database) ? database : p.join(app.basePath, database);
}

void _replicaOptions(Command<int> command) => command.argParser
  ..addOption('disk', help: 'The storage disk of the replica (s3, local...).')
  ..addOption(
    'path',
    help: 'Where on the disk (default: replicas/<database file name>).',
  );

(Disk, String) _replica(Command<int> command, String database) {
  final r = command.argResults!;
  final disk = App.make<StorageManager>().disk(r['disk'] as String?);
  final path =
      r['path'] as String? ??
      'replicas/${p.basenameWithoutExtension(database)}';
  return (disk, path);
}

/// `db:replicate`: ships the SQLite database to a disk continuously
/// ([SqliteReplicator], Blueprint #30) until stopped.
final class DbReplicateCommand extends DaravelCommand {
  DbReplicateCommand(super.createApp) {
    _replicaOptions(this);
    argParser
      ..addOption('interval', defaultsTo: '1', help: 'Seconds between syncs.')
      ..addFlag('once', negatable: false, help: 'Sync once and exit.')
      ..addOption(
        'checkpoint-pages',
        defaultsTo: '1000',
        help: 'Log size (frames) at which the log is folded and restarted.',
      )
      ..addOption(
        'snapshot-hours',
        defaultsTo: '24',
        help: 'A new snapshot (generation) after this many hours.',
      )
      ..addOption('retain', defaultsTo: '2', help: 'Generations kept.');
  }

  @override
  String get name => 'db:replicate';

  @override
  String get description =>
      'Stream the SQLite database to a disk (S3, R2, ...) as it changes.';

  @override
  Future<int> run() => withApp((app) async {
    final database = _sqlitePath(app);
    if (database == null) {
      return 1;
    }
    final r = argResults!;
    final (disk, path) = _replica(this, database);
    final replicator = SqliteReplicator(
      database,
      disk,
      prefix: path,
      checkpointPages: int.parse(r['checkpoint-pages'] as String),
      snapshotInterval: Duration(
        minutes: (double.parse(r['snapshot-hours'] as String) * 60).round(),
      ),
      retain: int.parse(r['retain'] as String),
    );
    void report(ReplicationSync sync) {
      if (sync.newGeneration) {
        stdout.writeln(
          'Generation ${sync.generation} (${sync.reason}): snapshot and '
          '${sync.frames} frames.',
        );
      } else if (sync.frames > 0) {
        stdout.writeln('Shipped ${sync.frames} frames.');
      }
    }

    try {
      if (r['once'] == true) {
        report(await replicator.sync());
        return 0;
      }
      stdout.writeln(
        'Replicating ${p.relative(database, from: app.basePath)} to '
        '${disk.name}:$path (Ctrl+C to stop).',
      );
      final stop = Completer<void>();
      final signals = [
        ProcessSignal.sigint.watch().listen((_) {
          if (!stop.isCompleted) {
            stop.complete();
          }
        }),
        if (!Platform.isWindows)
          ProcessSignal.sigterm.watch().listen((_) {
            if (!stop.isCompleted) {
              stop.complete();
            }
          }),
      ];
      final interval = Duration(
        milliseconds: (double.parse(r['interval'] as String) * 1000).round(),
      );
      while (!stop.isCompleted) {
        try {
          report(await replicator.sync());
        } on Object catch (error) {
          stderr.writeln('Sync failed, retrying: $error');
        }
        await Future.any([Future<void>.delayed(interval), stop.future]);
      }
      // What was committed until the signal.
      report(await replicator.sync());
      for (final signal in signals) {
        await signal.cancel();
      }
      return 0;
    } finally {
      replicator.close();
    }
  });
}

/// `db:restore`: rebuilds the SQLite database from its replica.
final class DbRestoreCommand extends DaravelCommand {
  DbRestoreCommand(super.createApp) {
    _replicaOptions(this);
    argParser
      ..addOption('to', help: 'Restore here instead of the database file.')
      ..addOption('generation', help: 'This generation, not the newest.')
      ..addOption(
        'at',
        help: 'The state as of this time (ISO 8601, e.g. 2026-10-29T08:00Z).',
      )
      ..addFlag(
        'if-missing',
        negatable: false,
        help: 'Do nothing when the database exists (container start).',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Replace an existing file (stop the application first).',
      );
  }

  @override
  String get name => 'db:restore';

  @override
  String get description => 'Restore the SQLite database from its replica.';

  @override
  Future<int> run() => withApp((app) async {
    final database = _sqlitePath(app);
    if (database == null) {
      return 1;
    }
    final r = argResults!;
    final target = r['to'] as String? ?? database;
    if (File(target).existsSync() && r['if-missing'] == true) {
      stdout.writeln('${p.basename(target)} exists; nothing restored.');
      return 0;
    }
    final at = r['at'] as String?;
    final (disk, path) = _replica(this, database);
    try {
      final result = await restoreReplica(
        disk,
        path,
        target,
        generation: r['generation'] as String?,
        at: at == null ? null : DateTime.parse(at),
        overwrite: r['force'] == true,
      );
      stdout.writeln(
        'Restored ${p.basename(target)} from generation ${result.generation}: '
        'snapshot and ${result.segments} segments (${result.frames} frames).',
      );
      return 0;
    } on ReplicationException catch (error) {
      stderr.writeln(error.message);
      return 1;
    }
  });
}

/// `db:replicas`: the generations of the database's replica.
final class DbReplicasCommand extends DaravelCommand {
  DbReplicasCommand(super.createApp) {
    _replicaOptions(this);
  }

  @override
  String get name => 'db:replicas';

  @override
  String get description => 'List the generations of the SQLite replica.';

  @override
  Future<int> run() => withApp((app) async {
    final database = _sqlitePath(app);
    if (database == null) {
      return 1;
    }
    final (disk, path) = _replica(this, database);
    final generations = await listReplicaGenerations(disk, path);
    if (generations.isEmpty) {
      stdout.writeln('No replica at ${disk.name}:$path.');
      return 0;
    }
    for (final id in generations.reversed) {
      final segments = await disk.files(
        '${ReplicaLayout.generation(path, id)}/wal',
      );
      DateTime time(String file) => DateTime.fromMillisecondsSinceEpoch(
        int.parse(RegExp(r'(\d+)\.\w+\.gz$').firstMatch(file)![1]!),
        isUtc: true,
      );
      final last = segments.isEmpty
          ? null
          : (segments.map(time).toList()..sort()).last;
      stdout.writeln(
        '$id  ${segments.length} segments'
        '${last == null ? '' : ', last ${last.toIso8601String()}'}',
      );
    }
    return 0;
  });
}
