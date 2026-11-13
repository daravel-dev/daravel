import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:test/test.dart';

final class Fine extends Job {
  const Fine();

  @override
  String get jobName => 'fine';

  @override
  Map<String, Object?> toJson() => const {};

  @override
  Future<void> handle(JobContext ctx) async {}
}

/// The MySQL run of `daravel`'s `test/queue/retry_all_test.dart`:
/// `QueueManager.retryAllFailed` a page at a time on a MySQL
/// `failed_jobs`. `DARAVEL_RETRY_ALL_ROWS` sets how many (3 000 by
/// default). Runs only with `DARAVEL_TEST_MYSQL`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_MYSQL'];
  final rows = int.tryParse(
    Platform.environment['DARAVEL_RETRY_ALL_ROWS'] ?? '',
  );

  group('MySQL', () {
    late Application app;

    setUp(() async {
      final uri = Uri.parse(url!);
      final user = uri.userInfo.split(':');
      app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_CONNECTION': 'mysql',
            'DB_HOST': uri.host,
            'DB_PORT': '${uri.port}',
            'DB_DATABASE': uri.path.replaceFirst('/', ''),
            'DB_USERNAME': user.first,
            'DB_PASSWORD': user.length > 1 ? user[1] : '',
            'QUEUE_CONNECTION': 'database',
            'CACHE_STORE': 'array',
          })
          .withLogLevel(LogLevel.critical)
          .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
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

    test('pages, the bound, an unreadable row skipped', () async {
      final count = rows ?? 3000;
      await app.run(() async {
        final now = Clock.now().toUtc();
        for (var start = 0; start < count; start += 500) {
          await DB.table('failed_jobs').insert([
            for (var i = start; i < start + 500 && i < count; i++)
              {
                'uuid': 'u$i',
                'connection': 'database',
                'queue': 'default',
                'payload': i == count ~/ 2
                    ? '{"job":"fine","uuid":5}'
                    : JobPayload.forJob(const Fine(), uuid: 'u$i').encode(),
                'exception': 'StateError: boom',
                'failed_at': now,
              },
          ]);
        }
        final manager = App.make<QueueManager>();
        final rssBefore = ProcessInfo.currentRss;
        var maxRss = rssBefore;
        var after = 0;
        int? upTo;
        var retried = 0;
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
          if (ProcessInfo.currentRss > maxRss) {
            maxRss = ProcessInfo.currentRss;
          }
          retried += result.retried.length;
          if (result.remaining == 0) {
            break;
          }
          after = result.after;
          upTo = result.upTo;
        }
        expect(retried, count - 1);
        expect(await Queue.size('default'), count - 1);
        expect(
          [for (final job in await manager.processor.failedJobs.all()) job.id],
          [count ~/ 2 + 1],
        );
        if (rows != null) {
          stdout.writeln(
            'RETRY_ALL MySQL: $count rows, $calls calls in ${watch.elapsed}, '
            'RSS +${(maxRss - rssBefore) >> 20} MiB at most',
          );
        }
      });
    }, timeout: const Timeout(Duration(minutes: 10)));
  }, skip: url == null || url.isEmpty ? 'needs DARAVEL_TEST_MYSQL' : false);
}
