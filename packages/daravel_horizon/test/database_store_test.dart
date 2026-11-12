import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support/store_contract.dart';

/// `DARAVEL_TEST_PG=postgres://user:secret@127.0.0.1:5432/db` and
/// `DARAVEL_TEST_MYSQL=mysql://user:secret@127.0.0.1:3306/db` add the
/// PostgreSQL and MySQL runs of the contract, as the core's suites do.
final String? pgUrl = Platform.environment['DARAVEL_TEST_PG'];
final String? mysqlUrl = Platform.environment['DARAVEL_TEST_MYSQL'];

Map<String, String> mysqlEnv(String url) {
  final uri = Uri.parse(url);
  final user = uri.userInfo.split(':');
  return {
    'DB_CONNECTION': 'mysql',
    'DB_HOST': uri.host,
    'DB_PORT': '${uri.hasPort ? uri.port : 3306}',
    'DB_DATABASE': uri.pathSegments.isEmpty ? '' : uri.pathSegments.first,
    'DB_USERNAME': user.first,
    'DB_PASSWORD': user.length > 1 ? user[1] : '',
  };
}

void main() {
  final runs = <String, Map<String, String> Function()>{
    'database, SQLite file': () => {
      'DB_CONNECTION': 'sqlite',
      'DB_DATABASE': p.join(
        Directory.systemTemp.createTempSync('horizon_db_store_').path,
        'db.sqlite',
      ),
    },
    if (pgUrl != null && pgUrl!.isNotEmpty)
      'database, PostgreSQL': () => {
        'DB_CONNECTION': 'pgsql',
        'DB_URL': pgUrl!,
      },
    if (mysqlUrl != null && mysqlUrl!.isNotEmpty)
      'database, MySQL': () => mysqlEnv(mysqlUrl!),
  };

  for (final MapEntry(key: name, value: env) in runs.entries) {
    late Application app;
    horizonStoreContract(
      name,
      () async {
        app = Application.configure(basePath: Directory.systemTemp.path)
            .withEnv({'APP_ENV': 'testing', ...env()})
            .withLogLevel(LogLevel.critical)
            .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
            .create();
        await app.boot();
        await app.run(() async {
          // A fresh set of tables each time, on a shared server too.
          final schema = await Schema.builder();
          await const CreateHorizonTables().down(schema);
          await const CreateHorizonTables().up(schema);
        });
        final store = DatabaseHorizonStore(
          app.container.make<DatabaseManager>(),
        );
        return (
          store: store as HorizonStore,
          setNow: (DateTime at) => Clock.travelTo(at),
          settle: store.flush,
        );
      },
      tearDownStore: () async {
        Clock.restore();
        await app.run(
          () async => const CreateHorizonTables().down(await Schema.builder()),
        );
        await app.shutdown();
      },
    );

    // Two workers flush the same job at once (failed on one, retried at
    // once on the other): neither sees the other's row before it commits.
    // Only a server with several connections can show it, not SQLite.
    test('$name: two stores flushing the same job at once lose no other '
        'record, and the newest one wins', () async {
      Application open() =>
          Application.configure(basePath: Directory.systemTemp.path)
              .withEnv({'APP_ENV': 'testing', ...env()})
              .withLogLevel(LogLevel.critical)
              .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
              .create();
      final first = open();
      final second = open();
      await first.boot();
      await second.boot();
      addTearDown(() async {
        await first.run(
          () async => const CreateHorizonTables().down(await Schema.builder()),
        );
        await first.shutdown();
        await second.shutdown();
      });
      await first.run(() async {
        final schema = await Schema.builder();
        await const CreateHorizonTables().down(schema);
        await const CreateHorizonTables().up(schema);
      });
      DatabaseHorizonStore store(Application app) => DatabaseHorizonStore(
        app.container.make<DatabaseManager>(),
        flushEvery: const Duration(hours: 1),
        appMetrics: app.container.make<AppMetrics>(),
      );
      final a = store(first);
      final b = store(second);
      final now = DateTime.now().millisecondsSinceEpoch;
      RecordedJob job(String uuid, String status, int at) => RecordedJob(
        uuid: uuid,
        name: 'SendInvoice',
        queue: 'default',
        status: status,
        at: at,
      );
      for (var round = 0; round < 10; round++) {
        for (var i = 0; i < 99; i++) {
          await a.record(job('a$round-$i', 'completed', now));
          await b.record(job('b$round-$i', 'completed', now));
        }
        // The same job: failed on the first, completed later on the
        // second.
        await a.record(job('x$round', 'failed', now));
        await b.record(job('x$round', 'completed', now + 1));
        await Future.wait([a.flush(), b.flush()]);
      }
      final rows = await first.run(() => DB.table('horizon_jobs').count());
      expect(rows, 10 * (99 + 99 + 1), reason: 'no batch dropped');
      for (var round = 0; round < 10; round++) {
        expect((await a.job('x$round'))?.status, 'completed');
      }
      double dropped(Application app) => app.container
          .make<AppMetrics>()
          .registry
          .counter('horizon_store_dropped_total', '')
          .value({'store': 'database', 'reason': 'error'});
      expect(dropped(first) + dropped(second), 0);
    }, skip: name.contains('SQLite') ? 'one connection: no race' : null);

    // The trim is two statements per table (ids with LIMIT, then a delete
    // by id): DELETE … LIMIT is not portable, so each dialect runs it.
    test('$name: each write trims at most trimBatch old rows; prune trims '
        'all', () async {
      final trimmed = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({'APP_ENV': 'testing', ...env()})
          .withLogLevel(LogLevel.critical)
          .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
          .create();
      await trimmed.boot();
      addTearDown(() async {
        Clock.restore();
        await trimmed.run(
          () async => const CreateHorizonTables().down(await Schema.builder()),
        );
        await trimmed.shutdown();
      });
      await trimmed.run(() async {
        final schema = await Schema.builder();
        await const CreateHorizonTables().down(schema);
        await const CreateHorizonTables().up(schema);
      });
      Future<int> rows() => trimmed.run(() => DB.table('horizon_jobs').count());
      final start = DateTime.utc(2026, 11, 12, 9);
      Clock.travelTo(start);
      final store = DatabaseHorizonStore(
        trimmed.container.make<DatabaseManager>(),
        trimBatch: 2,
        trimEvery: Duration.zero,
        flushEvery: const Duration(hours: 1),
      );
      RecordedJob at(String uuid, String status) => RecordedJob(
        uuid: uuid,
        name: 'SendInvoice',
        queue: 'default',
        status: status,
        at: Clock.now().millisecondsSinceEpoch,
      );
      for (var i = 0; i < 5; i++) {
        await store.record(at('old$i', 'completed'));
      }
      await store.record(at('oldfail', 'failed'));
      await store.flush();
      expect(await rows(), 6);
      Clock.travelTo(start.add(const Duration(minutes: 61)));
      await store.record(at('new', 'completed'));
      await store.flush();
      expect(await rows(), 5, reason: '2 trimmed by the write');
      // The 3 old jobs left, and their 3 rows in horizon_job_counts.
      expect(await store.prune(), 6);
      expect(await rows(), 2, reason: 'new, and the failed one kept');
    });
  }
}
