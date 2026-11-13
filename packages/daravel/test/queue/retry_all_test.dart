import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Always fails: retried on the `sync` queue, it fails again at once and
/// gets a new `failed_jobs` row.
final class Doomed extends Job {
  const Doomed();

  static int runs = 0;

  @override
  String get jobName => 'doomed';

  @override
  Map<String, Object?> toJson() => const {};

  @override
  Future<void> handle(JobContext ctx) async {
    runs++;
    throw StateError('doomed');
  }
}

final class Fine extends Job {
  const Fine();

  @override
  String get jobName => 'fine';

  @override
  Map<String, Object?> toJson() => const {};

  @override
  Future<void> handle(JobContext ctx) async {}
}

/// `QueueManager.retryAllFailed` (`queue:retry all`, Horizon's retry-all):
/// a page at a time, bounded by the last failed job there was when it
/// began, one run at a time.
void main() {
  test('sync: a job failing again at once is retried once per run; the '
      'call ends', () async {
    Doomed.runs = 0;
    final app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'QUEUE_CONNECTION': 'sync',
        })
        .withLogLevel(LogLevel.critical)
        .withJobs([JobDefinition('doomed', (_) => const Doomed())])
        .create();
    await app.boot();
    addTearDown(app.shutdown);
    await app.run(() async {
      final manager = App.make<QueueManager>();
      final failed = manager.processor.failedJobs;
      for (var i = 0; i < 5; i++) {
        await failed.log(
          connection: 'sync',
          queue: 'default',
          payload: JobPayload.forJob(const Doomed(), uuid: 'd$i').encode(),
          exception: 'StateError: doomed',
        );
      }
      final result = await manager
          .retryAllFailed()
          .then<RetryAllResult?>((r) => r, onError: (Object e) => null)
          .timeout(const Duration(seconds: 20));
      expect(Doomed.runs, 5, reason: 'each of the 5 rows once');
      expect(result?.remaining, 0);
      expect(result?.upTo, 5);
      // The 5 rows retried are gone; each failed again: 5 new rows.
      expect([
        for (final job in await failed.all()) job.id,
      ], unorderedEquals([6, 7, 8, 9, 10]));
    });
  });

  final rows = int.tryParse(
    Platform.environment['DARAVEL_RETRY_ALL_ROWS'] ?? '',
  );
  final pg = Platform.environment['DARAVEL_TEST_PG'];
  // The MySQL run is in daravel_mysql (test/retry_all_test.dart).
  final runs = <String, Map<String, String> Function()>{
    'SQLite': () => {
      'DB_CONNECTION': 'sqlite',
      'DB_DATABASE': p.join(
        Directory.systemTemp.createTempSync('retry_all_').path,
        'db.sqlite',
      ),
    },
    if (pg != null && pg.isNotEmpty)
      'PostgreSQL': () => {'DB_CONNECTION': 'pgsql', 'DB_URL': pg},
  };
  for (final MapEntry(key: name, value: env) in runs.entries) {
    group(name, () {
      late Application app;

      setUp(() async {
        app = Application.configure(basePath: Directory.systemTemp.path)
            .withEnv({
              'APP_ENV': 'testing',
              'QUEUE_CONNECTION': 'database',
              'CACHE_STORE': 'array',
              ...env(),
            })
            .withLogLevel(LogLevel.critical)
            .withMigrations(const [CreateJobsTable()])
            .withJobs([JobDefinition('fine', (_) => const Fine())])
            .create();
        await app.boot();
        await app.run(() async {
          final schema = await Schema.builder();
          for (final table in ['jobs', 'job_batches', 'failed_jobs']) {
            await schema.dropIfExists(table);
          }
          await const CreateJobsTable().up(schema);
        });
      });

      tearDown(() async {
        await app.run(() async {
          final schema = await Schema.builder();
          for (final table in ['jobs', 'job_batches', 'failed_jobs']) {
            await schema.dropIfExists(table);
          }
        });
        await app.shutdown();
      });

      /// [count] failed jobs, the one at [corrupt] unreadable; inserted in
      /// chunks, directly (as many workers would have logged them).
      Future<void> seed(int count, {int? corrupt}) => app.run(() async {
        final now = Clock.now().toUtc();
        for (var start = 0; start < count; start += 500) {
          await DB.table('failed_jobs').insert([
            for (var i = start; i < start + 500 && i < count; i++)
              {
                'uuid': 'u$i',
                'connection': 'database',
                'queue': 'default',
                'payload': i == corrupt
                    ? '{"job":"fine","uuid":5}'
                    : JobPayload.forJob(const Fine(), uuid: 'u$i').encode(),
                'exception': 'StateError: boom',
                'failed_at': now,
              },
          ]);
        }
      });

      test('pages: limit, budget and remaining; an unreadable row is '
          'skipped and reported; nothing is pushed after the answer', () async {
        final count = rows ?? 3000;
        await seed(count, corrupt: count ~/ 2);
        await app.run(() async {
          final manager = App.make<QueueManager>();
          final rssBefore = ProcessInfo.currentRss;
          var maxRss = rssBefore;
          var after = 0;
          int? upTo;
          var retried = 0;
          var skipped = 0;
          var calls = 0;
          final watch = Stopwatch()..start();
          while (true) {
            final call = Stopwatch()..start();
            final result = await manager.retryAllFailed(
              limit: 1000,
              budget: const Duration(seconds: 10),
              after: after,
              upTo: upTo,
            );
            calls++;
            expect(call.elapsed, lessThan(const Duration(seconds: 12)));
            final rss = ProcessInfo.currentRss;
            if (rss > maxRss) {
              maxRss = rss;
            }
            retried += result.retried.length;
            skipped += result.skippedCount;
            // Nothing goes on after the answer.
            final queued = await Queue.size('default');
            await Future<void>.delayed(const Duration(milliseconds: 200));
            expect(await Queue.size('default'), queued);
            if (result.remaining == 0) {
              break;
            }
            expect(
              result.remaining,
              count - (result.after),
              reason: 'the rows after the cursor',
            );
            after = result.after;
            upTo = result.upTo;
          }
          expect(retried, count - 1);
          expect(skipped, 1);
          expect(await Queue.size('default'), count - 1);
          expect(
            [
              for (final job in await manager.processor.failedJobs.all())
                job.id,
            ],
            [count ~/ 2 + 1],
          );
          printOnFailure(
            '$name: $count rows, $calls calls in ${watch.elapsed}, RSS '
            '+${(maxRss - rssBefore) >> 20} MiB at most',
          );
          if (rows != null) {
            stdout.writeln(
              'RETRY_ALL $name: $count rows, $calls calls in '
              '${watch.elapsed}, RSS +${(maxRss - rssBefore) >> 20} MiB '
              'at most',
            );
          }
        });
      }, timeout: const Timeout(Duration(minutes: 10)));

      test('two runs at once: the second is refused', () async {
        await seed(600);
        await app.run(() async {
          final manager = App.make<QueueManager>();
          final first = manager.retryAllFailed(pageSize: 50);
          await expectLater(
            manager.retryAllFailed(),
            throwsA(isA<RetryAllRunningException>()),
          );
          final result = await first;
          expect(result.retried, hasLength(600));
          expect(await Queue.size('default'), 600, reason: 'each once');
          // Free again.
          expect((await manager.retryAllFailed()).remaining, 0);
        });
      });
    });
  }
}
