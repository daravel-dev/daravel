@Tags(['integration'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

/// Runs only when `DARAVEL_TEST_PG` is set, as the core's PostgreSQL suite:
/// `DARAVEL_TEST_PG=postgres://daravel:secret@127.0.0.1:5432/daravel_test`.
final String? pgUrl = Platform.environment['DARAVEL_TEST_PG'];

final String marksPath =
    '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_pg_marks_$pid.txt';

/// Blocks its worker past its timeout on its first attempt, inside a
/// transaction holding a row lock; the next attempt updates the same row.
final class Locker extends Job {
  const Locker();
  @override
  String get jobName => 'locker';
  @override
  int get tries => 3;
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {
    await DB.transaction(() async {
      await DB.table('horizon_pg_rows').where('id', 1).update({
        'attempt': ctx.attempt,
      });
      if (ctx.attempt == 1) {
        final watch = Stopwatch()..start();
        while (watch.elapsed < const Duration(seconds: 20)) {}
      }
    });
    File(marksPath).writeAsStringSync('done:${ctx.attempt}\n');
  }
}

final class _CreateRows extends Migration {
  const _CreateRows();
  @override
  String get name => '2026_11_06_000000_create_horizon_pg_rows';
  @override
  Future<void> up(SchemaBuilder schema) =>
      schema.create('horizon_pg_rows', (t) {
        t.id();
        t.integer('attempt').defaultTo(0);
      });
  @override
  Future<void> down(SchemaBuilder schema) =>
      schema.dropIfExists('horizon_pg_rows');
}

Application pgApp() =>
    Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'pgsql',
          'DB_URL': pgUrl ?? '',
          'QUEUE_CONNECTION': 'database',
          'CACHE_STORE': 'file',
        })
        .withLogLevel(LogLevel.critical)
        .withMigrations(const [CreateJobsTable(), _CreateRows()])
        .withJobs([JobDefinition('locker', (_) => const Locker())])
        .create();

void main() {
  if (pgUrl == null || pgUrl!.isEmpty) {
    test('postgres (skipped: DARAVEL_TEST_PG not set)', () {}, skip: true);
    return;
  }

  test(
    'on PostgreSQL the master ends the session of a killed worker: the job is '
    'reclaimed and the next worker writes the same row at once',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      if (File(marksPath).existsSync()) {
        File(marksPath).deleteSync();
      }
      final app = pgApp();
      await app.boot();
      addTearDown(app.shutdown);
      await app.run(() async {
        for (final table in [
          'jobs',
          'failed_jobs',
          'job_batches',
          'horizon_pg_rows',
          'migrations',
        ]) {
          await DB.statement('DROP TABLE IF EXISTS $table');
        }
        await App.make<Migrator>().run();
        await DB.table('horizon_pg_rows').insert({'id': 1, 'attempt': 0});
        await Queue.push(const Locker(), queue: 'a');
      });
      final events = <(String, Map<String, Object?>)>[];
      DateTime? killedAt;
      final master = HorizonMaster(
        pgApp,
        HorizonConfig(
          plans: const [
            SupervisorPlan(
              name: SupervisorName('s'),
              queues: [QueueName('a')],
              balance: BalanceStrategy.off,
              maxProcesses: 1,
              // The first attempt blocks 20 s inside its transaction: the
              // master kills it past its timeout (2 s + killGrace 1 s), well
              // inside retry_after (90 s), so the job is reclaimed at once.
              timeout: Duration(seconds: 2),
              sleep: Duration(milliseconds: 50),
            ),
          ],
          heartbeat: const Duration(milliseconds: 200),
          killGrace: const Duration(seconds: 1),
        ),
        driver: (c) => app.container.make<QueueManager>().connection(c),
        terminateSession: (connection, id) async {
          final driver = await app.container.make<DatabaseManager>().connection(
            connection,
          );
          return driver is SessionTerminatingDriver &&
              await driver.terminateSession(id);
        },
        logger: Logger(minimumLevel: LogLevel.critical),
        onEvent: (event, data) {
          events.add((event, data));
          if (event == 'WorkerKilled') {
            killedAt ??= DateTime.now();
          }
        },
      );
      addTearDown(() => master.stop(timeout: const Duration(seconds: 20)));
      await master.start();
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (!(File(marksPath).existsSync() &&
          File(marksPath).readAsStringSync().contains('done:2'))) {
        if (DateTime.now().isAfter(deadline)) {
          fail('attempt 2 never finished: $events');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      final finishedAt = DateTime.now();
      final killed = events.where((e) => e.$1 == 'WorkerKilled').single.$2;
      expect(killed['reason'], 'timeout');
      final timedOut = events.where((e) => e.$1 == 'JobTimedOut').single.$2;
      expect(timedOut['reclaimed'], isTrue, reason: 'reclaimed, not left');
      expect(killed['sessionsTerminated'], greaterThanOrEqualTo(1));
      expect(killed['failed'], 0);
      expect(
        finishedAt.difference(killedAt!),
        lessThan(const Duration(seconds: 5)),
        reason:
            'the reclaimed attempt does not wait on the lock of the killed one',
      );
      final row = await app.run(
        () => DB.table('horizon_pg_rows').where('id', 1).first(),
      );
      expect(row?['attempt'], 2, reason: 'attempt 1 was rolled back');
    },
  );
}
