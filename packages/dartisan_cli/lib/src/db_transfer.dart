import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';

import '../dartisan_cli.dart';

/// The connection [spec] names: a configured connection (`sqlite`, `pgsql`,
/// ...) or a URL: `sqlite:database/old.sqlite`, `sqlite::memory:`,
/// `pgsql://user:secret@host:5432/app?sslmode=require`,
/// `mysql://user@host/app`. Relative SQLite paths resolve against
/// [basePath].
ConnectionConfig connectionFromSpec(
  String spec,
  DatabaseConfig config, {
  required String basePath,
}) {
  final configured = config.connections[spec];
  if (configured != null) {
    return configured;
  }
  try {
    return ConnectionConfig.fromUrl(spec, basePath: basePath);
  } on FormatException catch (error) {
    throw FormatException(
      '${error.message} Use a configured connection '
      '(${config.connections.keys.join(', ')}) or a URL such as '
      'pgsql://user:pass@host:5432/app or sqlite:database/old.sqlite.',
    );
  }
}

/// A connection for messages: the driver and database, never a password.
String describeConnection(ConnectionConfig c) => c.driver == 'sqlite'
    ? 'sqlite:${c.database}'
    : '${c.driver}://${c.host}:${c.port}/${c.database}';

/// What [DatabaseTransfer.run] did (or would do, for a dry run).
final class TransferReport {
  TransferReport();

  /// Rows copied per table, in copy order.
  final Map<String, int> rows = <String, int>{};

  /// Migrations run on the target.
  final List<String> migrated = <String>[];
  final List<String> notes = <String>[];
}

/// Copies the rows of [source] into [target] (`dartisan db:transfer`).
///
/// The target's schema comes from the application's [migrations] (run on
/// it unless [migrate] is false), so each database gets its own dialect's
/// column types instead of a translation of the source's. Tables are copied
/// parents first (from the target's foreign keys), all in one target
/// transaction: a failure leaves the target as it was. Values are adapted
/// to the target's column types, and PostgreSQL sequences continue after
/// the copied ids.
final class DatabaseTransfer {
  DatabaseTransfer({
    required this.source,
    required this.target,
    required this.migrations,
    this.migrate = true,
    this.truncate = false,
    this.tables,
    this.chunk = 500,
    this.log,
  });

  final DatabaseManager source;
  final DatabaseManager target;
  final List<Migration> migrations;
  final bool migrate;

  /// Empty the target tables first (otherwise they must be empty).
  final bool truncate;

  /// Only these tables (all shared tables when null).
  final Set<String>? tables;
  final int chunk;
  final void Function(String line)? log;

  /// The ledger of each database: never copied.
  static const String ledger = 'migrations';

  Future<TransferReport> run({bool dryRun = false}) async {
    final report = TransferReport();
    if (migrate && !dryRun) {
      report.migrated.addAll(await Migrator(target, migrations).run());
    }
    final sourceSchema = SchemaBuilder(await source.executor());
    final targetSchema = SchemaBuilder(await target.executor());
    final sourceTables = (await sourceSchema.getTables())
        .where((t) => t != ledger && !t.startsWith('sqlite_'))
        .toSet();
    final wanted = tables;
    if (dryRun) {
      // The target may not be migrated yet: report what the source has.
      for (final table in (wanted ?? sourceTables).toList()..sort()) {
        report.rows[table] = await source.table(table).count();
      }
      if (migrate) {
        report.notes.add('the target would be migrated first');
      }
      return report;
    }
    final targetTables = (await targetSchema.getTables()).toSet();
    var names = sourceTables.intersection(targetTables);
    if (wanted != null) {
      final unknown = wanted.difference(names);
      if (unknown.isNotEmpty) {
        throw StateError('Not in both databases: ${unknown.join(', ')}.');
      }
      names = wanted;
    }
    for (final missing in sourceTables.difference(targetTables)) {
      report.notes.add(
        '$missing: not in the target (no migration creates it); skipped',
      );
    }
    final order = await _parentsFirst(names);
    final columns = <String, List<ColumnInfo>>{};
    final sourceColumns = <String, List<ColumnInfo>>{};
    for (final table in order) {
      columns[table] = await targetSchema.getColumns(table);
      sourceColumns[table] = await sourceSchema.getColumns(table);
      final dropped = sourceColumns[table]!
          .map((c) => c.name)
          .toSet()
          .difference(columns[table]!.map((c) => c.name).toSet());
      if (dropped.isNotEmpty) {
        report.notes.add(
          '$table: ${dropped.join(', ')} not in the target; not copied',
        );
      }
    }
    if (!truncate) {
      final filled = [
        for (final table in order)
          if (await target.table(table).count() > 0) table,
      ];
      if (filled.isNotEmpty) {
        throw StateError(
          'The target already has rows in ${filled.join(', ')}; pass '
          '--truncate to replace them.',
        );
      }
    }
    final dialect = target.dialectOf();
    var deferred = const <(String, String)>[];
    await target.transaction(() async {
      final executor = await target.executor();
      // Order already respects foreign keys; on SQLite and MySQL checks
      // are also relaxed for cycles and self-references.
      switch (dialect) {
        case SqlDialect.sqlite:
          await executor.execute('PRAGMA defer_foreign_keys = ON');
        case SqlDialect.mysql:
          await executor.execute('SET FOREIGN_KEY_CHECKS = 0');
        case SqlDialect.postgres:
          // Checked per statement otherwise: a self-reference to a later
          // row (or a cycle) would fail between chunks.
          deferred = await _deferForeignKeys(executor, order.toSet());
      }
      if (truncate) {
        for (final table in order.reversed) {
          await target.table(table).delete();
        }
      }
      for (final table in order) {
        report.rows[table] = await _copy(
          table,
          sourceColumns[table]!,
          columns[table]!,
          dialect,
        );
        log?.call('$table: ${report.rows[table]} row(s)');
      }
      if (dialect == SqlDialect.mysql) {
        await executor.execute('SET FOREIGN_KEY_CHECKS = 1');
      }
      if (dialect == SqlDialect.postgres) {
        // Check every deferred key now, then restore the definitions.
        await executor.execute('SET CONSTRAINTS ALL IMMEDIATE');
        for (final (table, constraint) in deferred) {
          await executor.execute(
            'ALTER TABLE ${_pgQuote(table)} ALTER CONSTRAINT '
            '${_pgQuote(constraint)} NOT DEFERRABLE',
          );
        }
        for (final table in order) {
          await _resetSequences(executor, table, columns[table]!);
        }
      }
    });
    return report;
  }

  Future<int> _copy(
    String table,
    List<ColumnInfo> from,
    List<ColumnInfo> to,
    SqlDialect dialect,
  ) async {
    final types = {for (final c in to) c.name: c.type};
    final shared = [
      for (final c in from)
        if (types.containsKey(c.name)) c,
    ];
    if (shared.isEmpty) {
      return 0;
    }
    final names = [for (final c in shared) c.name];
    final keys = [
      for (final c in shared)
        if (c.primary) c,
    ];
    // Keyset pages on a single integer key; offsets otherwise.
    final key = keys.length == 1 && _isInteger(keys.single.type)
        ? keys.single.name
        : null;
    final batch = (30000 ~/ names.length).clamp(1, chunk);
    var copied = 0;
    Object? last;
    var offset = 0;
    while (true) {
      var query = source.table(table).select(names);
      if (key != null) {
        query = query.orderBy(key);
        if (last != null) {
          query = query.where(key, '>', last);
        }
      } else {
        query = query
            .orderBy(keys.isEmpty ? names.first : keys.first.name)
            .offset(offset);
      }
      final rows = await query.limit(chunk).get();
      if (rows.isEmpty) {
        return copied;
      }
      final converted = [
        for (final row in rows)
          {
            for (final name in names)
              name: adaptValue(row[name], types[name]!, dialect),
          },
      ];
      for (var i = 0; i < converted.length; i += batch) {
        final end = i + batch > converted.length ? converted.length : i + batch;
        await target.table(table).insert(converted.sublist(i, end));
      }
      copied += rows.length;
      offset += rows.length;
      if (key != null) {
        last = rows.last[key];
      }
      if (rows.length < chunk) {
        return copied;
      }
    }
  }

  static bool _isInteger(String type) {
    final t = type.toLowerCase();
    return t.contains('int') || t.contains('serial');
  }

  /// Continues each PostgreSQL sequence after the copied ids, so the next
  /// insert does not collide with them.
  Future<void> _resetSequences(
    QueryExecutor executor,
    String table,
    List<ColumnInfo> columns,
  ) async {
    for (final column in columns.where((c) => c.autoIncrement)) {
      final rows = await executor.select(
        'SELECT pg_get_serial_sequence(\$1, \$2) AS seq',
        [_pgQuote(table), column.name],
      );
      final sequence = rows.isEmpty ? null : rows.single['seq'];
      if (sequence is! String) {
        continue;
      }
      await executor.select(
        'SELECT setval(\$1, COALESCE((SELECT MAX(${_pgQuote(column.name)}) '
        'FROM ${_pgQuote(table)}), 0) + 1, false)',
        [sequence],
      );
    }
  }

  /// Makes the non-deferrable foreign keys of [tables] deferred for this
  /// transaction; returns them (table, constraint) to restore.
  Future<List<(String, String)>> _deferForeignKeys(
    QueryExecutor executor,
    Set<String> tables,
  ) async {
    final rows = await executor.select(
      'SELECT table_name, constraint_name '
      'FROM information_schema.table_constraints '
      "WHERE constraint_type = 'FOREIGN KEY' "
      "AND table_schema = current_schema() AND is_deferrable = 'NO'",
    );
    final keys = [
      for (final row in rows)
        if (tables.contains(row['table_name']))
          ('${row['table_name']}', '${row['constraint_name']}'),
    ];
    for (final (table, constraint) in keys) {
      await executor.execute(
        'ALTER TABLE ${_pgQuote(table)} ALTER CONSTRAINT '
        '${_pgQuote(constraint)} DEFERRABLE INITIALLY DEFERRED',
      );
    }
    return keys;
  }

  static String _pgQuote(String name) => '"${name.replaceAll('"', '""')}"';

  /// [names] with referenced tables before the tables referencing them
  /// (the target's foreign keys); cycles keep alphabetical order.
  Future<List<String>> _parentsFirst(Set<String> names) async {
    final parents = <String, Set<String>>{
      for (final name in names) name: <String>{},
    };
    for (final (child, parent) in await _foreignKeys(names)) {
      if (child != parent && names.contains(child) && names.contains(parent)) {
        parents[child]!.add(parent);
      }
    }
    final order = <String>[];
    final done = <String>{};
    final remaining = names.toList()..sort();
    while (remaining.isNotEmpty) {
      final ready = remaining
          .where((t) => parents[t]!.every(done.contains))
          .toList();
      final next = ready.isEmpty ? [remaining.first] : ready;
      for (final table in next) {
        order.add(table);
        done.add(table);
        remaining.remove(table);
      }
    }
    return order;
  }

  /// (table, referenced table) pairs of the target.
  Future<List<(String, String)>> _foreignKeys(Set<String> names) async {
    final executor = await target.executor();
    switch (executor.dialect) {
      case SqlDialect.sqlite:
        return [
          for (final table in names)
            for (final row in await executor.select(
              'PRAGMA foreign_key_list(${_pgQuote(table)})',
            ))
              (table, '${row['table']}'),
        ];
      case SqlDialect.postgres:
        final rows = await executor.select(
          'SELECT tc.table_name AS child, ccu.table_name AS parent '
          'FROM information_schema.table_constraints tc '
          'JOIN information_schema.constraint_column_usage ccu '
          'ON tc.constraint_name = ccu.constraint_name '
          'AND tc.table_schema = ccu.table_schema '
          "WHERE tc.constraint_type = 'FOREIGN KEY' "
          'AND tc.table_schema = current_schema()',
        );
        return [for (final r in rows) ('${r['child']}', '${r['parent']}')];
      case SqlDialect.mysql:
        final rows = await executor.select(
          'SELECT TABLE_NAME AS child, REFERENCED_TABLE_NAME AS parent '
          'FROM information_schema.KEY_COLUMN_USAGE '
          'WHERE TABLE_SCHEMA = DATABASE() AND REFERENCED_TABLE_NAME IS NOT NULL',
        );
        return [for (final r in rows) ('${r['child']}', '${r['parent']}')];
    }
  }
}

/// [value] read from another database, as [dialect] stores a column of
/// [type]: JSON documents as text, 0/1 as booleans on PostgreSQL, dates as
/// Laravel's `Y-m-d H:i:s` text on SQLite and MySQL.
Object? adaptValue(Object? value, String type, SqlDialect dialect) {
  if (value == null) {
    return null;
  }
  if (value is Map || value is List) {
    return jsonEncode(value);
  }
  final t = type.toLowerCase();
  if (dialect == SqlDialect.postgres) {
    if (t.startsWith('bool')) {
      return switch (value) {
        bool() => value,
        num() => value != 0,
        String() => const {
          '1',
          't',
          'true',
          'y',
          'yes',
        }.contains(value.toLowerCase()),
        _ => value,
      };
    }
    return value;
  }
  if (value is DateTime) {
    final d = value.toUtc();
    String two(int v) => v.toString().padLeft(2, '0');
    final date =
        '${d.year.toString().padLeft(4, '0')}-${two(d.month)}-${two(d.day)}';
    return t == 'date'
        ? date
        : '$date ${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }
  return value;
}

/// `db:transfer --from=<connection> --to=<connection>`: copies an
/// application's data to another database (SQLite to PostgreSQL, ...).
final class DbTransferCommand extends DaravelCommand {
  DbTransferCommand(super.createApp) {
    argParser
      ..addOption(
        'from',
        mandatory: true,
        help: 'Source: a connection name or URL (sqlite:path, pgsql://...).',
      )
      ..addOption(
        'to',
        mandatory: true,
        help: 'Target: a connection name or URL.',
      )
      ..addMultiOption('tables', help: 'Only these tables.')
      ..addOption('chunk', defaultsTo: '500', help: 'Rows read per query.')
      ..addFlag(
        'migrate',
        defaultsTo: true,
        help: 'Run the migrations on the target first.',
      )
      ..addFlag(
        'truncate',
        negatable: false,
        help: 'Delete the rows already in the target tables.',
      )
      ..addFlag(
        'dry-run',
        negatable: false,
        help: 'Show what would be copied, change nothing.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help: 'Allow it with APP_ENV=production.',
      );
  }

  @override
  String get name => 'db:transfer';

  @override
  String get description =>
      'Copy the data to another database (the target is migrated first).';

  @override
  Future<int> run() => withApp((app) async {
    final r = argResults!;
    if (app.config.section<AppConfig>().env == 'production' &&
        r['force'] != true &&
        r['dry-run'] != true) {
      stderr.writeln(
        'APP_ENV=production: db:transfer writes into the target; pass '
        '--force to run it anyway.',
      );
      return 1;
    }
    final config = app.config.section<DatabaseConfig>();
    final from = connectionFromSpec(
      r['from'] as String,
      config,
      basePath: app.basePath,
    );
    final to = connectionFromSpec(
      r['to'] as String,
      config,
      basePath: app.basePath,
    );
    if (describeConnection(from) == describeConnection(to)) {
      stderr.writeln('Source and target are the same database.');
      return 64;
    }
    final db = app.container.make<DatabaseManager>();
    final source = db.forConnection('source', from);
    final target = db.forConnection('target', to);
    final only = (r['tables'] as List<String>).toSet();
    try {
      stdout.writeln(
        '${r['dry-run'] == true ? 'Would copy' : 'Copying'} '
        '${describeConnection(from)} → ${describeConnection(to)}',
      );
      final report = await DatabaseTransfer(
        source: source,
        target: target,
        migrations: app.container.make<Migrator>().migrations,
        migrate: r['migrate'] as bool,
        truncate: r['truncate'] as bool,
        tables: only.isEmpty ? null : only,
        chunk: int.parse(r['chunk'] as String),
        log: (line) => stdout.writeln('  $line'),
      ).run(dryRun: r['dry-run'] as bool);
      for (final migration in report.migrated) {
        stdout.writeln('Migrated $migration');
      }
      if (r['dry-run'] == true) {
        for (final MapEntry(:key, :value) in report.rows.entries) {
          stdout.writeln('  $key: $value row(s)');
        }
      }
      for (final note in report.notes) {
        stdout.writeln('  note: $note');
      }
      final total = report.rows.values.fold(0, (a, b) => a + b);
      stdout.writeln(
        '${r['dry-run'] == true ? 'Would copy' : 'Copied'} $total row(s) in '
        '${report.rows.length} table(s).',
      );
      return 0;
    } on StateError catch (error) {
      stderr.writeln(error.message);
      return 1;
    } finally {
      await source.closeAll();
      await target.closeAll();
    }
  });
}
