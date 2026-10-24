import '../database_manager.dart';
import '../query/query_builder.dart';
import 'schema_builder.dart';

/// A schema migration. [name] must be unique and stable (it is recorded in
/// the `migrations` table, Laravel-compatible: `id`, `migration`, `batch`).
abstract class Migration {
  const Migration();

  String get name;

  Future<void> up(SchemaBuilder schema);

  Future<void> down(SchemaBuilder schema);
}

/// Status row reported by `migrate:status`.
final class MigrationStatus {
  const MigrationStatus({required this.name, required this.ran, this.batch});

  final String name;
  final bool ran;
  final int? batch;
}

/// Runs migrations in batches (`migrate`, `migrate:rollback`,
/// `migrate:status`, `migrate:reset`).
final class Migrator {
  Migrator(this._db, List<Migration> migrations)
    : migrations = List<Migration>.unmodifiable(migrations);

  static const String table = 'migrations';

  final DatabaseManager _db;
  final List<Migration> migrations;

  /// Creates the `migrations` table when missing.
  ///
  /// Same columns as Laravel's `DatabaseMigrationRepository`, compiled by the
  /// connection's grammar (`id`, `migration`, `batch`).
  Future<void> install() async {
    await SchemaBuilder(await _db.executor()).createIfNotExists(table, (t) {
      t.id();
      t.string('migration');
      t.integer('batch');
    });
  }

  /// Runs all pending migrations in one new batch; returns their names.
  Future<List<String>> run() async {
    await install();
    final ran = await _ranNames();
    final pending = migrations.where((m) => !ran.contains(m.name)).toList();
    if (pending.isEmpty) {
      return const <String>[];
    }
    final batch = await _lastBatch() + 1;
    final migrated = <String>[];
    for (final migration in pending) {
      await _db.transaction(() async {
        await migration.up(SchemaBuilder(await _db.executor()));
        await _ledger().insert({'migration': migration.name, 'batch': batch});
      });
      migrated.add(migration.name);
    }
    return migrated;
  }

  /// Rolls back the last [steps] batches; returns the migration names.
  Future<List<String>> rollback({int steps = 1}) async {
    await install();
    final rows = await _ledger()
        .select(['migration', 'batch'])
        .orderByDesc('batch')
        .orderByDesc('id')
        .get();
    if (rows.isEmpty) {
      return const <String>[];
    }
    final batches = <int>{};
    final targets = <String>[];
    for (final row in rows) {
      final batch = (row['batch'] as num).toInt();
      if (!batches.contains(batch) && batches.length >= steps) {
        break;
      }
      batches.add(batch);
      targets.add(row['migration'] as String);
    }
    return _rollbackNames(targets);
  }

  /// Drops every table and re-runs all migrations (`migrate:fresh`).
  Future<List<String>> fresh() async {
    final schema = SchemaBuilder(await _db.executor());
    await schema.dropAllTables();
    return run();
  }

  /// Rolls back every migration.
  Future<List<String>> reset() async {
    await install();
    final rows = await _ledger()
        .select(['migration'])
        .orderByDesc('batch')
        .orderByDesc('id')
        .get();
    return _rollbackNames(<String>[
      for (final row in rows) row['migration'] as String,
    ]);
  }

  /// Reports every known migration with its ran/batch state.
  Future<List<MigrationStatus>> status() async {
    await install();
    final rows = await _ledger().select(['migration', 'batch']).get();
    final batches = <String, int>{
      for (final row in rows)
        row['migration'] as String: (row['batch'] as num).toInt(),
    };
    return <MigrationStatus>[
      for (final migration in migrations)
        MigrationStatus(
          name: migration.name,
          ran: batches.containsKey(migration.name),
          batch: batches[migration.name],
        ),
    ];
  }

  Future<List<String>> _rollbackNames(List<String> names) async {
    final byName = <String, Migration>{for (final m in migrations) m.name: m};
    final rolledBack = <String>[];
    for (final name in names) {
      final migration = byName[name];
      if (migration == null) {
        throw StateError(
          'Migration [$name] was recorded in the database but is not registered '
          'in withMigrations(); cannot roll it back.',
        );
      }
      await _db.transaction(() async {
        await migration.down(SchemaBuilder(await _db.executor()));
        await _ledger().where('migration', name).delete();
      });
      rolledBack.add(name);
    }
    return rolledBack;
  }

  /// The `migrations` table, quoted by the connection's grammar.
  QueryBuilder _ledger() => _db.table(table);

  Future<Set<String>> _ranNames() async {
    final rows = await _ledger().select(['migration']).get();
    return <String>{for (final row in rows) row['migration'] as String};
  }

  Future<int> _lastBatch() async {
    final value = await _ledger().max('batch');
    return value is num ? value.toInt() : 0;
  }
}
