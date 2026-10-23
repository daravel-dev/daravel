import '../database_manager.dart';
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
  Future<void> install() async {
    await _db.statement(
      'CREATE TABLE IF NOT EXISTS "$table" ('
      '"id" INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, '
      '"migration" VARCHAR(255) NOT NULL, '
      '"batch" INTEGER NOT NULL)',
    );
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
        await _db.statement(
          'INSERT INTO "$table" ("migration", "batch") VALUES (?, ?)',
          <Object?>[migration.name, batch],
        );
      });
      migrated.add(migration.name);
    }
    return migrated;
  }

  /// Rolls back the last [steps] batches; returns the migration names.
  Future<List<String>> rollback({int steps = 1}) async {
    await install();
    final rows = await _db.select(
      'SELECT "migration", "batch" FROM "$table" ORDER BY "batch" DESC, "id" DESC',
    );
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

  /// Rolls back every migration.
  Future<List<String>> reset() async {
    await install();
    final rows = await _db.select(
      'SELECT "migration" FROM "$table" ORDER BY "batch" DESC, "id" DESC',
    );
    return _rollbackNames(<String>[
      for (final row in rows) row['migration'] as String,
    ]);
  }

  /// Reports every known migration with its ran/batch state.
  Future<List<MigrationStatus>> status() async {
    await install();
    final rows = await _db.select('SELECT "migration", "batch" FROM "$table"');
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
        await _db.statement(
          'DELETE FROM "$table" WHERE "migration" = ?',
          <Object?>[name],
        );
      });
      rolledBack.add(name);
    }
    return rolledBack;
  }

  Future<Set<String>> _ranNames() async {
    final rows = await _db.select('SELECT "migration" FROM "$table"');
    return <String>{for (final row in rows) row['migration'] as String};
  }

  Future<int> _lastBatch() async {
    final rows = await _db.select('SELECT MAX("batch") AS b FROM "$table"');
    final value = rows.isEmpty ? null : rows.first['b'];
    return value is num ? value.toInt() : 0;
  }
}
