import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

RecordedJob job(String uuid, {String status = 'completed', DateTime? at}) =>
    RecordedJob(
      uuid: uuid,
      name: 'SendInvoice',
      queue: 'default',
      status: status,
      at: (at ?? Clock.now()).millisecondsSinceEpoch,
      durationMs: 5,
    );

/// The rules of the `database` store beyond the shared contract: nothing
/// lost silently, writes outside the job's transaction, bounded tables.
void main() {
  test('HORIZON_STORE=redis without withRedis() stops the boot with a '
      'configuration error, rather than falling back to process', () async {
    final app = redisWithoutRedis();
    await expectLater(
      app.boot(),
      throwsA(
        isA<ConfigException>().having(
          (e) => e.message,
          'message',
          contains('HORIZON_STORE=redis'),
        ),
      ),
    );
  });

  late Directory dir;
  late Application app;
  late DatabaseManager db;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('horizon_db_rules_');
    app = Application.configure(basePath: dir.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'sqlite',
          'DB_DATABASE': p.join(dir.path, 'db.sqlite'),
          'METRICS_ENABLED': 'true',
        })
        .withLogLevel(LogLevel.critical)
        .withMigrations(const [CreateHorizonTables()])
        .create();
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
    db = app.container.make<DatabaseManager>();
  });
  tearDown(() async {
    Clock.restore();
    await app.shutdown();
    try {
      dir.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows may still hold the file.
    }
  });

  Future<int> rows(String table) => app.run(() => DB.table(table).count());

  double dropped(String reason) => app.container
      .make<AppMetrics>()
      .registry
      .counter('horizon_store_dropped_total', '')
      .value({'store': 'database', 'reason': reason});

  test(
    'a full buffer drops the oldest records, counted, never silently',
    () async {
      final store = DatabaseHorizonStore(
        db,
        maxBuffered: 3,
        batchSize: 100,
        flushEvery: const Duration(hours: 1),
        appMetrics: app.container.make<AppMetrics>(),
      );
      for (var i = 0; i < 5; i++) {
        await store.record(job('j$i'));
      }
      expect(dropped('overflow'), 2);
      await store.flush();
      final kept = await store.recent('completed');
      expect([for (final j in kept) j.uuid], ['j4', 'j3', 'j2']);
    },
  );

  test('a write the database refuses is dropped, counted', () async {
    final store = DatabaseHorizonStore(
      db,
      flushEvery: const Duration(hours: 1),
      appMetrics: app.container.make<AppMetrics>(),
    );
    await app.run(() => Schema.dropIfExists('horizon_jobs'));
    await store.record(job('a'));
    await store.flush();
    expect(dropped('error'), 1);
  });

  test(
    "a record made inside the job's transaction is written outside it: "
    'the transaction rolled back, the job is still recorded as failed',
    () async {
      final store = DatabaseHorizonStore(
        db,
        flushEvery: const Duration(milliseconds: 50),
      );
      await app.run(() async {
        try {
          await DB.transaction(() async {
            await store.record(job('a', status: 'failed'));
            throw StateError('the job failed');
          });
        } on StateError {
          // Rolled back.
        }
      });
      // The timer flushes in the root zone, after the rollback.
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (await rows('horizon_jobs') == 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect((await store.job('a'))?.status, 'failed');
    },
  );

  test(
    'a flush started inside a transaction does not join it (SQLite, one '
    'connection: it waits for the transaction, then fails, counted)',
    () async {
      final store = DatabaseHorizonStore(
        db,
        flushEvery: const Duration(hours: 1),
        appMetrics: app.container.make<AppMetrics>(),
      );
      await app.run(() async {
        await DB.transaction(() async {
          await store.record(job('a'));
          await store.flush();
        });
      });
      // Had it joined the transaction, the row would be there (committed).
      expect(await rows('horizon_jobs'), 0);
      expect(dropped('error'), 1);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'a flush waiting for the database never holds the worker: recording '
    'returns at once, and the batch is written once the database is free',
    () async {
      final store = DatabaseHorizonStore(
        db,
        flushEvery: const Duration(milliseconds: 20),
      );
      final release = Completer<void>();
      // Another holder of the one SQLite connection, for a second.
      final holding = app.run(
        () => DB.transaction(() async {
          await DB.table('horizon_monitored_tags').get();
          await release.future;
        }),
      );
      final watch = Stopwatch()..start();
      for (var i = 0; i < 50; i++) {
        await store.record(job('j$i'));
        // The job path never waits for the write.
        expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
      }
      expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
      // The timer's flush is waiting on the lock meanwhile.
      await Future<void>.delayed(const Duration(milliseconds: 300));
      release.complete();
      await holding;
      await store.flush();
      expect(await rows('horizon_jobs'), 50, reason: 'nothing dropped');
    },
  );

  test(
    'close writes what is buffered; later records are dropped, counted',
    () async {
      final store = DatabaseHorizonStore(
        db,
        flushEvery: const Duration(hours: 1),
        appMetrics: app.container.make<AppMetrics>(),
      );
      await store.record(job('a'));
      await store.close();
      expect(await rows('horizon_jobs'), 1);
      await store.record(job('b'));
      expect(dropped('overflow'), 1);
    },
  );
}

/// A top-level factory, as `withHorizon(createApp:)` needs.
Application redisWithoutRedis() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'HORIZON_STORE': 'redis',
        })
        .withLogLevel(LogLevel.critical)
        .withHorizon(createApp: redisWithoutRedis)
        .create();
