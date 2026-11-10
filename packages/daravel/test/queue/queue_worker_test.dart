import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final List<String> ran = <String>[];

final class Mark extends Job {
  const Mark(this.label, {this.fail = false});

  factory Mark.fromJson(Map<String, Object?> json) =>
      Mark(json['label']! as String, fail: json['fail'] == true);

  final String label;
  final bool fail;

  @override
  String get jobName => 'mark';

  @override
  int get tries => 1;

  @override
  List<String> get tags => ['label:$label'];

  @override
  Map<String, Object?> toJson() => {'label': label, 'fail': fail};

  @override
  Future<void> handle(JobContext ctx) async {
    ran.add('${ctx.queue}:$label');
    if (fail) {
      throw StateError('mark $label failed');
    }
  }
}

void main() {
  Application? app;

  Future<void> boot(String connection) async {
    ran.clear();
    app =
        Application.configure(
              basePath: Directory.systemTemp
                  .createTempSync('daravel_worker_')
                  .path,
            )
            .withEnv({
              'APP_ENV': 'testing',
              'DB_DATABASE': ':memory:',
              'QUEUE_CONNECTION': connection,
            })
            .withMigrations(const [CreateJobsTable(), CreateCacheTable()])
            .withJobs([JobDefinition('mark', Mark.fromJson)])
            .create();
    await app!.boot();
    await app!.run(() => App.make<Migrator>().run());
  }

  tearDown(() async {
    await app?.shutdown();
    app = null;
  });

  group('QueueWorker.reassign', () {
    test('changes the queues popped from the next job on', () async {
      await boot('memory');
      await app!.run(() async {
        await Queue.push(const Mark('a1'), queue: 'a');
        await Queue.push(const Mark('a2'), queue: 'a');
        await Queue.push(const Mark('b1'), queue: 'b');
        final worker = QueueWorker(Queue.manager);
        final driver = Queue.connection();
        const options = WorkerOptions(queues: ['a']);
        expect(await worker.runNextJob(driver, options), isTrue);
        worker.reassign(['b']);
        expect(worker.queues, ['b']);
        expect(await worker.runNextJob(driver, options), isTrue);
        expect(await worker.runNextJob(driver, options), isFalse);
        expect(ran, ['a:a1', 'b:b1']);
        expect(await Queue.size('a'), 1);
      });
    });

    test('an idle worker polls its new queues at once', () async {
      await boot('memory');
      await app!.run(() async {
        await Queue.push(const Mark('late'), queue: 'b');
        final worker = QueueWorker(Queue.manager);
        final running = worker.run(
          const WorkerOptions(queues: ['a'], sleep: Duration(seconds: 30)),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(worker.queues, ['a']);
        expect(ran, isEmpty);
        final watch = Stopwatch()..start();
        worker.reassign(['b']);
        while (ran.isEmpty && watch.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
        expect(ran, ['b:late']);
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        worker.stop();
        expect(await running.timeout(const Duration(seconds: 5)), 0);
        expect(worker.queues, isEmpty, reason: 'run forgets its queues');
      });
    });

    test('stop() still wakes an idle worker', () async {
      await boot('memory');
      await app!.run(() async {
        final worker = QueueWorker(Queue.manager);
        final running = worker.run(
          const WorkerOptions(queues: ['a'], sleep: Duration(seconds: 30)),
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
        worker
          ..reassign(['b'])
          ..stop();
        expect(await running.timeout(const Duration(seconds: 5)), 0);
      });
    });

    test('called before run, it replaces the queues run starts with', () async {
      await boot('memory');
      await app!.run(() async {
        await Queue.push(const Mark('b1'), queue: 'b');
        final worker = QueueWorker(Queue.manager)..reassign(['b']);
        await worker.run(
          const WorkerOptions(queues: ['a'], stopWhenEmpty: true),
        );
        expect(ran, ['b:b1']);
      });
    });
  });

  for (final connection in ['memory', 'database']) {
    group('browsing and reclaiming ($connection)', () {
      test('pending and delayed list jobs without reserving them', () async {
        await boot(connection);
        await app!.run(() async {
          await Queue.push(const Mark('one'));
          await Queue.push(const Mark('two'));
          await Queue.later(const Duration(hours: 2), const Mark('later'));
          await Queue.later(const Duration(hours: 1), const Mark('sooner'));
          final driver = Queue.connection() as BrowsableQueueDriver;

          final pending = await driver.pending('default');
          expect([for (final j in pending) j.displayName], ['Mark', 'Mark']);
          expect(
            [for (final j in pending) j.tags.single],
            ['label:one', 'label:two'],
          );
          final first = pending.first;
          expect(first.jobName, 'mark');
          expect(first.queue, 'default');
          expect(first.uuid, isNotEmpty);
          expect(first.attempts, 0);
          expect(first.pushedAt, isNotNull);
          expect(
            first.availableAt.isAfter(
              Clock.now().toUtc().add(const Duration(seconds: 5)),
            ),
            isFalse,
          );
          expect(JobPayload.decode(first.payload).data['label'], 'one');
          expect(first.toJson()['tags'], ['label:one']);

          final paged = await driver.pending('default', limit: 1, offset: 1);
          expect(paged.single.tags, ['label:two']);
          expect(await driver.pending('default', limit: 0), isEmpty);

          final delayed = await driver.delayed('default');
          expect(
            [for (final j in delayed) j.tags.single],
            ['label:sooner', 'label:later'],
          );
          expect(
            delayed.first.availableAt.isAfter(Clock.now().toUtc()),
            isTrue,
          );

          // Nothing was reserved: a worker still gets every ready job.
          await QueueWorker(Queue.manager)
              .run(const WorkerOptions(stopWhenEmpty: true));
          expect(ran, ['default:one', 'default:two']);
          expect(await driver.pending('default'), isEmpty);
          expect(await driver.delayed('default'), hasLength(2));
        });
      });

      test(
        'reclaim hands a reserved job back at once, keeping attempts',
        () async {
          await boot(connection);
          await app!.run(() async {
            await Queue.push(const Mark('lost'));
            final driver = Queue.connection() as ReclaimableQueueDriver;
            final reserved = (await driver.pop('default'))!;
            expect(reserved.attempts, 1);
            expect(await driver.pop('default'), isNull);
            expect(
              await (driver as BrowsableQueueDriver).pending('default'),
              isEmpty,
            );

            expect(await driver.reclaim('default', reserved.id), isTrue);
            final again = (await driver.pop('default'))!;
            expect(again.id, reserved.id);
            expect(again.attempts, 2, reason: 'the lost attempt counts');
            expect(again.payload.uuid, reserved.payload.uuid);

            await driver.delete(again);
            expect(await driver.reclaim('default', again.id), isFalse);
            expect(await driver.reclaim('other', reserved.id), isFalse);
          });
        },
      );
    });
  }

  test('lifecycle events carry what a dashboard records', () async {
    await boot('memory');
    await app!.run(() async {
      final events = <Object>[];
      Event.listen<JobProcessing>(events.add);
      Event.listen<JobProcessed>(events.add);
      Event.listen<JobExceptionOccurred>(events.add);
      Event.listen<JobFailed>(events.add);
      Context.add('tenant', 'acme');
      await Queue.push(const Mark('ok'));
      await Queue.push(const Mark('bad', fail: true));
      await QueueWorker(Queue.manager)
          .run(const WorkerOptions(stopWhenEmpty: true));

      final processing = events.whereType<JobProcessing>().toList();
      expect(processing, hasLength(2));
      expect(processing.first.uuid, isNotEmpty);
      expect(processing.first.displayName, 'Mark');
      expect(processing.first.tags, ['label:ok']);
      expect(processing.first.pushedAt, isNotNull);
      expect(processing.first.context?['data'], {'tenant': 'acme'});
      // The job's own timeout (Job.timeout: 1 minute), as no --timeout.
      expect(processing.first.timeout, const Duration(minutes: 1));

      final processed = events.whereType<JobProcessed>().single;
      expect(processed.uuid, processing.first.uuid);
      expect(processed.attempt, 1);

      final thrown = events.whereType<JobExceptionOccurred>().single;
      expect(thrown.uuid, processing.last.uuid);
      expect(thrown.attempt, 1);
      expect(thrown.stackTrace, isNotNull);
      expect(thrown.willRetry, isFalse);

      final failed = events.whereType<JobFailed>().single;
      expect(failed.uuid, processing.last.uuid);
      expect(failed.stackTrace, isNotNull);
      final record = await Queue.manager.processor.failedJobs.find(
        failed.failedId!,
      );
      expect(record?.uuid, failed.uuid);
    });
  });

  test('JobProcessing.timeout is the one the processor enforces: the '
      "worker's --timeout over the job's own", () async {
    await boot('memory');
    await app!.run(() async {
      final events = <JobProcessing>[];
      Event.listen<JobProcessing>(events.add);
      await Queue.push(const Mark('ok'));
      await QueueWorker(Queue.manager).run(
        const WorkerOptions(stopWhenEmpty: true, timeout: Duration(seconds: 7)),
      );
      expect(events.single.timeout, const Duration(seconds: 7));
    });
  });

  test('the events keep their old constructors', () {
    const processing = JobProcessing(
      connection: 'c',
      queue: 'q',
      jobName: 'j',
      jobId: 1,
      attempt: 1,
    );
    expect(processing.uuid, isNull);
    expect(processing.tags, isEmpty);
    const failed = JobFailed(
      connection: 'c',
      queue: 'q',
      jobName: 'j',
      jobId: 1,
      error: 'e',
    );
    expect(failed.failedId, isNull);
  });
}
