import 'dart:async';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart' as t;

import '../daravel_test.dart';

/// One application per test file with migrations run once and every test
/// wrapped in a transaction that is rolled back (Laravel `RefreshDatabase`).
///
/// ```dart
/// final db = refreshDatabase(() => createApp(env: {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'}));
///
/// void main() {
///   db.test('creates a user', () async {
///     (await db.client.post('/api/users', json: {...})).assertCreated();
///     await assertDatabaseHas('users', {'email': 'ana@example.com'});
///   });
/// }
/// ```
///
/// Fakes (`Event.fake()`, `Queue.fake()`) and the [Clock] are restored after
/// every test. Application transactions inside a test become savepoints and
/// their after-commit callbacks still fire.
final class DatabaseTestHarness {
  DatabaseTestHarness._(this._create, {this.seed = false});

  final Application Function() _create;

  /// Runs the root seeder once after migrating.
  final bool seed;

  Application? _app;

  /// The booted application (available inside tests and `setUp`).
  Application get app {
    final app = _app;
    if (app == null) {
      throw StateError(
        'The application is booted in setUpAll; use it inside tests.',
      );
    }
    return app;
  }

  /// A client for [app].
  TestClient get client => TestClient(app);

  Future<void> _setUpAll() async {
    final app = _create();
    await app.boot();
    await app.run(() async {
      await App.make<Migrator>().run();
      if (seed) {
        await App.make<SeederRegistry>().run();
      }
    });
    _app = app;
  }

  Future<void> _tearDownAll() async {
    await _app?.shutdown();
    _app = null;
  }

  /// Runs [body] in the app scope inside a rolled-back transaction.
  Future<T> transaction<T>(FutureOr<T> Function() body) async {
    try {
      return await app.run(
        () => App.make<DatabaseManager>().rollbackAfter(() async => body()),
      );
    } finally {
      await app.run(() async {
        App.make<EventDispatcher>().restore();
        App.make<QueueManager>().restore();
      });
      Clock.restore();
    }
  }

  /// Declares a test whose body runs in [transaction].
  void test(
    String description,
    FutureOr<void> Function() body, {
    Object? skip,
    t.Timeout? timeout,
  }) => t.test(
    description,
    () => transaction(body),
    skip: skip,
    timeout: timeout,
  );
}

/// Registers `setUpAll`/`tearDownAll` for a shared application and returns
/// the harness. Call it at the top of `main()` (or a `group`).
DatabaseTestHarness refreshDatabase(
  Application Function() create, {
  bool seed = false,
}) {
  final harness = DatabaseTestHarness._(create, seed: seed);
  t.setUpAll(harness._setUpAll);
  t.tearDownAll(harness._tearDownAll);
  return harness;
}

/// Fresh migrations for the current app (Laravel `DatabaseMigrations`):
/// drops every table and migrates again. Call inside `app.run`.
Future<void> migrateFresh() => App.make<Migrator>().fresh();

QueryBuilder _where(
  String table,
  Map<String, Object?> data,
  String? connection,
) {
  final query = DB.table(table, connection: connection);
  for (final entry in data.entries) {
    if (entry.value == null) {
      query.whereNull(entry.key);
    } else {
      query.where(entry.key, entry.value);
    }
  }
  return query;
}

/// A row matching [data] exists in [table].
Future<void> assertDatabaseHas(
  String table,
  Map<String, Object?> data, {
  String? connection,
}) async {
  if (!await _where(table, data, connection).exists()) {
    final sample = await DB.table(table, connection: connection).limit(5).get();
    t.fail('No row in [$table] matches $data. First rows: $sample');
  }
}

/// No row matching [data] exists in [table].
Future<void> assertDatabaseMissing(
  String table,
  Map<String, Object?> data, {
  String? connection,
}) async {
  if (await _where(table, data, connection).exists()) {
    t.fail('Found a row in [$table] matching $data.');
  }
}

/// [table] has exactly [count] rows.
Future<void> assertDatabaseCount(
  String table,
  int count, {
  String? connection,
}) async {
  final actual = await DB.table(table, connection: connection).count();
  if (actual != count) {
    t.fail('Expected $count rows in [$table] but found $actual.');
  }
}

/// [table] is empty.
Future<void> assertDatabaseEmpty(String table, {String? connection}) =>
    assertDatabaseCount(table, 0, connection: connection);

/// [model] (or the row matching a map in [table]) is soft deleted.
Future<void> assertSoftDeleted(
  Object modelOrTable, [
  Map<String, Object?> data = const {},
  String column = 'deleted_at',
]) async {
  final (table, where) = _target(modelOrTable, data);
  final query = _where(table, where, null).whereNotNull(column);
  if (!await query.exists()) {
    t.fail('Expected a soft deleted row in [$table] matching $where.');
  }
}

/// [model] (or a row matching a map in [table]) is not soft deleted.
Future<void> assertNotSoftDeleted(
  Object modelOrTable, [
  Map<String, Object?> data = const {},
  String column = 'deleted_at',
]) async {
  final (table, where) = _target(modelOrTable, data);
  if (!await _where(table, where, null).whereNull(column).exists()) {
    t.fail('Expected a non-deleted row in [$table] matching $where.');
  }
}

/// The row of [model] exists.
Future<void> assertModelExists(Model model) async {
  final (table, where) = _target(model, const {});
  await assertDatabaseHas(table, where);
}

/// The row of [model] does not exist (hard deleted).
Future<void> assertModelMissing(Model model) async {
  final (table, where) = _target(model, const {});
  await assertDatabaseMissing(table, where);
}

(String, Map<String, Object?>) _target(
  Object modelOrTable,
  Map<String, Object?> data,
) {
  if (modelOrTable is Model) {
    return (
      modelOrTable.table,
      {modelOrTable.modelDefinition.primaryKey: modelOrTable.key},
    );
  }
  return (modelOrTable as String, data);
}
