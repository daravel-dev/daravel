import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import 'support/test_databases.dart';

final class Attempt extends Model {
  static final ModelDefinition<Attempt> definition = ModelDefinition<Attempt>(
    table: 'attempts',
    factory: Attempt.new,
    guarded: [],
    casts: {'deadline_at': Cast.dateTime, 'submitted_at': Cast.dateTime},
  );
  @override
  ModelDefinition<Attempt> get modelDefinition => Attempt.definition;
}

/// #178: a `DateTime` bound by the query builder is stored and compared on
/// SQLite in the format models write, Laravel's `Grammar::getDateFormat()`
/// (`Y-m-d H:i:s`), which `Connection::prepareBindings` applies to every
/// `DateTimeInterface` binding. SQLite compares dates as text, so the ISO
/// form (`2026-11-05T17:43:00.000Z`) sorted after any same-day value
/// written by a model (the space sorts before `T`).
void main() {
  late DatabaseManager db;

  setUp(() async {
    db = sqliteInMemory();
    final schema = SchemaBuilder(await db.executor());
    await schema.create('attempts', (t) {
      t.id();
      t.dateTime('deadline_at').nullable();
      t.dateTime('submitted_at').nullable();
      t.timestamps();
    });
  });
  tearDown(() => db.closeAll());

  Future<Map<String, Object?>> row(Object id) async =>
      (await db.table('attempts').where('id', id).first())!;

  test('the query builder writes what a model writes', () async {
    final at = DateTime.utc(2026, 11, 5, 17, 40, 36, 52, 371);
    final model = await Attempt.definition.query(db: db).create({
      'deadline_at': at,
    });
    await db.table('attempts').where('id', model.attributes['id']).update({
      'submitted_at': at,
    });
    final stored = await row(model.attributes['id']!);
    expect(stored['deadline_at'], '2026-11-05 17:40:36');
    expect(stored['submitted_at'], '2026-11-05 17:40:36');
    final id = await db.table('attempts').insertGetId({'submitted_at': at});
    expect((await row(id!))['submitted_at'], '2026-11-05 17:40:36');
  });

  test('a same-day comparison against a model-written column', () async {
    // A session ending in two hours did not count as ended.
    final now = DateTime.utc(2026, 11, 5, 17, 43);
    await Attempt.definition.query(db: db).create({
      'deadline_at': now.add(const Duration(hours: 2)),
    });
    expect(
      await db.table('attempts').where('deadline_at', '>=', now).count(),
      1,
    );
    expect(
      await db.table('attempts').where('deadline_at', '<', now).count(),
      0,
    );
  });

  test('raw SQL and local times are bound in UTC, as models store them', () {
    return db.transaction(() async {
      final local = DateTime(2026, 11, 5, 9, 30);
      await db.insertGetId('INSERT INTO attempts (submitted_at) VALUES (?)', [
        local,
      ]);
      final stored = await db.select('SELECT submitted_at FROM attempts');
      final utc = local.toUtc();
      String two(int n) => n.toString().padLeft(2, '0');
      expect(
        stored.single['submitted_at'],
        '${utc.year}-${two(utc.month)}-${two(utc.day)} '
        '${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}',
      );
    });
  });

  test('values written by older versions read back and can be rewritten '
      'with the upgrade statement', () async {
    // What 1.26 and earlier stored for a query-builder DateTime.
    await db.statement('INSERT INTO attempts (submitted_at) VALUES (?)', [
      '2026-11-05T17:40:36.052371Z',
    ]);
    final model = await Attempt.definition.query(db: db).first();
    expect(
      model!['submitted_at'],
      DateTime.utc(2026, 11, 5, 17, 40, 36, 52, 371),
    );
    // The statement the upgrade note gives.
    await db.statement(
      "UPDATE attempts SET submitted_at = strftime('%Y-%m-%d %H:%M:%S', "
      "submitted_at) WHERE submitted_at LIKE '____-__-__T%'",
    );
    expect(
      (await db.select('SELECT submitted_at FROM attempts')).single.values,
      ['2026-11-05 17:40:36'],
    );
  });
}
