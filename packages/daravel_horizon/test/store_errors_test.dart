import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The database store on a SQLite file; top-level, as `withHorizon` needs.
Application storeApp([Map<String, String> env = const {}]) =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'sqlite',
          'QUEUE_CONNECTION': 'database',
          'HORIZON_ALLOW_SQLITE': 'true',
          'HORIZON_STORE': 'database',
          'LOG_CHANNEL': 'null',
          ...env,
        })
        .withLogLevel(LogLevel.warning)
        .withMigrations(const [CreateJobsTable(), CreateHorizonTables()])
        .withHorizon(createApp: storeApp)
        .create();

void main() {
  late Directory dir;
  late Application app;
  late TestClient client;
  late MemoryHandler logs;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('horizon_store_errors_');
    app = storeApp({'DB_DATABASE': p.join(dir.path, 'db.sqlite')});
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
    logs = await app.run(() async => Log.spy());
    HorizonDashboard.auth((Request request) => true);
    client = TestClient(app);
  });

  tearDown(() async {
    HorizonDashboard.auth(null);
    await app.shutdown();
    dir.deleteSync(recursive: true);
  });

  Future<void> drop(String table) =>
      app.run(() async => (await Schema.builder()).drop(table));

  for (final (method, path, table) in [
    ('POST', '/horizon/api/monitoring', 'horizon_monitored_tags'),
    ('DELETE', '/horizon/api/monitoring/billing', 'horizon_monitored_tags'),
  ]) {
    test('$method $path on a store that fails: a 500, logged; the process '
        'answers on', () async {
      await drop(table);
      final response = await client
          .send(method, path, json: {'tag': 'billing'})
          .timeout(const Duration(seconds: 10));
      response.assertStatus(500);
      expect(response.json, containsPair('message', isA<String>()));
      logs.assertLogged(LogLevel.error, 'Horizon dashboard');
      (await client.get('/horizon/api/masters')).assertOk();
    });
  }

  test('snapshot and prune on a store that fails throw in the caller\'s '
      'zone, never past it', () async {
    await drop('horizon_snapshots');
    final store = app.container.make<HorizonStore>() as DatabaseHorizonStore;
    await expectLater(
      app.run(store.snapshot).timeout(const Duration(seconds: 10)),
      throwsA(isA<QueryException>()),
    );
    await drop('horizon_jobs');
    await expectLater(
      app.run(store.prune).timeout(const Duration(seconds: 10)),
      throwsA(isA<QueryException>()),
    );
  });
}
