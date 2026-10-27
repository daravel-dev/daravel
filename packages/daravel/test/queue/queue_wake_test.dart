import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import '../database/support/test_databases.dart';

final List<String> ran = [];

final class Ping extends Job {
  const Ping(this.text);

  factory Ping.fromJson(Map<String, Object?> json) =>
      Ping(json['text']! as String);

  final String text;

  @override
  String get jobName => 'ping';

  @override
  Map<String, Object?> toJson() => {'text': text};

  @override
  Future<void> handle(JobContext context) async => ran.add(text);
}

/// An idle worker takes a pushed job right away instead of after `--sleep`
/// (Review #42, PERF-02).
void main() {
  group('memory queue', () {
    late Application app;

    setUp(() async {
      ran.clear();
      app =
          Application.configure(
                basePath: Directory.systemTemp
                    .createTempSync('daravel_wake_')
                    .path,
              )
              .withEnv({
                'APP_ENV': 'testing',
                'DB_DATABASE': ':memory:',
                'QUEUE_CONNECTION': 'memory',
              })
              .withJobs([JobDefinition('ping', Ping.fromJson)])
              .create();
      await app.boot();
    });
    tearDown(() => app.shutdown());

    test('a push wakes the idle worker', () async {
      await app.run(() async {
        final worker = QueueWorker(Queue.manager);
        final run = worker.run(
          const WorkerOptions(sleep: Duration(seconds: 30), maxJobs: 1),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        final watch = Stopwatch()..start();
        await Queue.dispatch(const Ping('now'));
        expect(await run.timeout(const Duration(seconds: 5)), 0);
        expect(ran, ['now']);
        expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
      });
    });

    test('stop() ends the wait', () async {
      await app.run(() async {
        final worker = QueueWorker(Queue.manager);
        final run = worker.run(
          const WorkerOptions(sleep: Duration(seconds: 30)),
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        worker.stop();
        expect(await run.timeout(const Duration(seconds: 2)), 0);
      });
    });
  });

  group('database queue', () {
    forEachDatabase((open) {
      late DatabaseManager first;
      late DatabaseManager second;

      setUp(() async {
        first = open();
        second = open();
        final schema = await freshSchema(first, [
          'jobs',
          'job_batches',
          'failed_jobs',
        ]);
        await const CreateJobsTable().up(schema);
      });
      tearDown(() async {
        await first.closeAll();
        await second.closeAll();
      });

      test('a push from another machine wakes a waiting worker on '
          'PostgreSQL; elsewhere it sleeps as before', () async {
        final worker = DatabaseQueue(first);
        // Two pools cannot share one in-memory SQLite database.
        final pusher = DatabaseQueue(
          first.dialectOf() == SqlDialect.sqlite ? first : second,
        );
        addTearDown(worker.stopWaiting);
        final notifies = first.dialectOf() == SqlDialect.postgres;
        final maxWait = notifies
            ? const Duration(seconds: 10)
            : const Duration(milliseconds: 300);

        // The first wait opens the listening connection.
        await worker.waitForWork(const ['default'], Duration.zero);
        final watch = Stopwatch()..start();
        final waiting = worker.waitForWork(const ['default'], maxWait);
        await Future<void>.delayed(const Duration(milliseconds: 200));
        await pusher.push(
          JobPayload.forJob(const Ping('remote')),
          queue: 'default',
        );
        await waiting;
        if (notifies) {
          expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
        } else {
          expect(watch.elapsed, greaterThanOrEqualTo(maxWait));
        }
        expect(await worker.pop('default'), isNotNull);
      });
    });
  });
}
