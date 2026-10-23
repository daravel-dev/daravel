import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final List<String> log = <String>[];

final class Greet extends Job {
  const Greet(this.name, {this.failTimes = 0, this.unique});

  factory Greet.fromJson(Map<String, Object?> json) => Greet(
    json['name']! as String,
    failTimes: (json['fail'] as num?)?.toInt() ?? 0,
    unique: json['unique'] as String?,
  );

  final String name;
  final int failTimes;
  final String? unique;

  @override
  String get jobName => 'greet';

  @override
  int get tries => 3;

  @override
  List<Duration> get backoff => const [
    Duration(seconds: 1),
    Duration(seconds: 5),
  ];

  @override
  String? get uniqueId => unique;

  @override
  Map<String, Object?> toJson() => {
    'name': name,
    'fail': failTimes,
    'unique': unique,
  };

  @override
  Future<void> handle(JobContext ctx) async {
    log.add('greet:$name:${ctx.attempt}');
    if (ctx.attempt <= failTimes) {
      throw StateError('flaky $name');
    }
  }

  @override
  Future<void> failed(Object error, StackTrace stackTrace) async =>
      log.add('failed:$name');
}

final class Slow extends Job {
  const Slow();
  @override
  String get jobName => 'slow';
  @override
  Duration get timeout => const Duration(milliseconds: 50);
  @override
  bool get failOnTimeout => true;
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {
    await Future<void>.delayed(const Duration(milliseconds: 200));
    log.add(ctx.cancelled ? 'slow:cancelled' : 'slow:done');
  }
}

final class Exclusive extends Job {
  const Exclusive(this.key);
  final String key;
  @override
  String get jobName => 'exclusive';
  @override
  List<JobMiddleware> get middleware => [
    WithoutOverlapping(key, releaseAfter: const Duration(seconds: 30)),
  ];
  @override
  Map<String, Object?> toJson() => {'key': key};
  @override
  Future<void> handle(JobContext ctx) async => log.add('exclusive:$key');
}

final class Controlled extends Job {
  const Controlled(this.action);
  final String action;
  @override
  String get jobName => 'controlled';
  @override
  Map<String, Object?> toJson() => {'action': action};
  @override
  Future<void> handle(JobContext ctx) async {
    switch (action) {
      case 'release':
        ctx.release(const Duration(seconds: 2));
      case 'delete':
        ctx.delete();
      case 'fail':
        ctx.fail(StateError('manual'));
    }
  }
}

final List<JobDefinition> definitions = [
  JobDefinition('greet', Greet.fromJson),
  JobDefinition('slow', (_) => const Slow()),
  JobDefinition('exclusive', (j) => Exclusive(j['key']! as String)),
  JobDefinition('controlled', (j) => Controlled(j['action']! as String)),
];

void main() {
  Application? app;

  Future<void> boot(String connection) async {
    log.clear();
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'QUEUE_CONNECTION': connection,
        })
        .withMigrations(const [CreateJobsTable()])
        .withJobs(definitions)
        .create();
    await app!.boot();
    await app!.run(() => App.make<Migrator>().run());
  }

  tearDown(() async {
    await app?.shutdown();
    app = null;
  });

  test('payload round-trips with Laravel-shaped keys', () {
    final payload = JobPayload.forJob(
      const Greet('ana', failTimes: 1),
      now: DateTime.utc(2026, 1, 1),
    );
    final json = payload.toJson();
    expect(
      json.keys,
      containsAll([
        'uuid',
        'displayName',
        'job',
        'maxTries',
        'backoff',
        'timeout',
        'data',
      ]),
    );
    expect(json['job'], 'greet');
    expect(json['displayName'], 'Greet');
    expect(json['maxTries'], 3);
    expect(json['backoff'], [1, 5]);
    expect(
      json['pushedAt'],
      DateTime.utc(2026, 1, 1).millisecondsSinceEpoch ~/ 1000,
    );
    final back = JobPayload.decode(payload.encode());
    expect(back.data, {'name': 'ana', 'fail': 1, 'unique': null});
    expect(back.uuid, payload.uuid);
    expect(
      () => JobRegistry().make('nope', const {}),
      throwsA(isA<UnknownJobException>()),
    );
  });

  test('sync connection runs jobs inline and records failures', () async {
    await boot('sync');
    await app!.run(() async {
      expect(await Queue.dispatch(const Greet('ana')), isNotNull);
      expect(log, ['greet:ana:1']);
      // Sync jobs get one attempt; a failure goes straight to failed_jobs.
      await Queue.push(const Greet('bo', failTimes: 5));
      expect(log, ['greet:ana:1', 'greet:bo:1', 'failed:bo']);
      final failed = await Queue.manager.processor.failedJobs.all();
      expect(failed.single.queue, 'default');
      expect(failed.single.exception, contains('flaky bo'));
    });
  });

  for (final connection in ['memory', 'database']) {
    test(
      '$connection: worker retries with backoff then fails after tries',
      () async {
        await boot(connection);
        await app!.run(() async {
          final manager = Queue.manager;
          final driver = manager.connection();
          await Queue.dispatch(
            const Greet('cy', failTimes: 1),
          ).onQueue('emails');
          await Queue.dispatch(const Greet('di', failTimes: 9));
          expect(await driver.size('emails'), 1);
          expect(await driver.size('default'), 1);
          final events = Event.fake();

          // First pass: both fail once and are released with 1s backoff.
          final worker = QueueWorker(manager);
          await worker.run(
            const WorkerOptions(
              queues: ['emails', 'default'],
              stopWhenEmpty: true,
            ),
          );
          expect(worker.processed, 2);
          expect(log, ['greet:cy:1', 'greet:di:1']);
          expect(
            await driver.pop('default'),
            isNull,
            reason: 'released job is delayed',
          );
          expect(
            events.of<JobExceptionOccurred>().every((e) => e.willRetry),
            isTrue,
          );

          // After the backoff they come back; cy succeeds, di keeps failing.
          await Future<void>.delayed(const Duration(milliseconds: 1100));
          final second = QueueWorker(manager);
          await second.run(
            const WorkerOptions(
              queues: ['emails', 'default'],
              stopWhenEmpty: true,
            ),
          );
          expect(log, contains('greet:cy:2'));
          expect(log, contains('greet:di:2'));
          expect(await driver.size('emails'), 0);

          // Third attempt of di exhausts tries=3 → failed_jobs + failed() hook.
          await Future<void>.delayed(const Duration(milliseconds: 5100));
          await QueueWorker(
            manager,
          ).run(const WorkerOptions(stopWhenEmpty: true));
          expect(log, contains('failed:di'));
          expect(await driver.size('default'), 0);
          final failed = await manager.processor.failedJobs.all();
          expect(failed.single.exception, contains('flaky di'));
          expect(events.dispatchedTimes<JobFailed>(), 1);
          expect(events.dispatchedTimes<JobProcessed>(), 1);
          Event.restore();
        });
      },
      timeout: const Timeout(Duration(minutes: 1)),
    );
  }

  test(
    'timeouts set cancelled and fail immediately with failOnTimeout',
    () async {
      await boot('memory');
      await app!.run(() async {
        await Queue.push(const Slow());
        await QueueWorker(
          Queue.manager,
        ).run(const WorkerOptions(stopWhenEmpty: true));
        final failed = await Queue.manager.processor.failedJobs.all();
        expect(failed.single.exception, contains('TimeoutException'));
        await Future<void>.delayed(const Duration(milliseconds: 250));
        expect(log, ['slow:cancelled']);
      });
    },
  );

  test('unique jobs are deduplicated until processed', () async {
    await boot('memory');
    await app!.run(() async {
      final first = await Queue.push(const Greet('ed', unique: 'ed'));
      final duplicate = await Queue.push(const Greet('ed', unique: 'ed'));
      expect(first, isNotNull);
      expect(duplicate, isNull);
      expect(await Queue.size(), 1);
      await QueueWorker(
        Queue.manager,
      ).run(const WorkerOptions(stopWhenEmpty: true));
      expect(await Queue.push(const Greet('ed', unique: 'ed')), isNotNull);
    });
  });

  test('job middleware and context controls (release/delete/fail)', () async {
    await boot('memory');
    await app!.run(() async {
      final driver = Queue.connection();
      final lock = Cache.store(
        'process',
      ).lock('overlap:exclusive:k1', owner: 'someone');
      expect(await lock.acquire(), isTrue);
      await Queue.push(const Exclusive('k1'));
      await Queue.push(const Exclusive('k2'));
      await QueueWorker(
        Queue.manager,
      ).run(const WorkerOptions(stopWhenEmpty: true));
      expect(log, ['exclusive:k2']);
      expect(
        await driver.size('default'),
        1,
        reason: 'k1 was released for later',
      );
      await lock.forceRelease();

      log.clear();
      await Queue.bulk([
        const Controlled('release'),
        const Controlled('delete'),
        const Controlled('fail'),
      ]);
      await QueueWorker(
        Queue.manager,
      ).run(const WorkerOptions(stopWhenEmpty: true));
      expect(
        await driver.size('default'),
        2,
        reason: 'released controlled job + released k1',
      );
      final failed = await Queue.manager.processor.failedJobs.all();
      expect(failed.single.exception, contains('manual'));
    });
  });

  test('dispatch inside a transaction waits for the commit', () async {
    await boot('memory');
    await app!.run(() async {
      final driver = Queue.connection();
      await DB.transaction(() async {
        await Queue.dispatch(const Greet('tx'));
        expect(await driver.size('default'), 0);
      });
      expect(await driver.size('default'), 1);
      await expectLater(
        DB.transaction(() async {
          await Queue.dispatch(const Greet('rolled-back'));
          throw StateError('rollback');
        }),
        throwsStateError,
      );
      expect(await driver.size('default'), 1);
      await DB.transaction(() async {
        await Queue.dispatch(const Greet('now')).beforeCommit();
        expect(await driver.size('default'), 2);
      });
    });
  });

  test('worker honours max-jobs, delay and restart signals', () async {
    await boot('memory');
    await app!.run(() async {
      await Queue.bulk([for (var i = 0; i < 3; i++) Greet('j$i')]);
      await Queue.later(const Duration(hours: 1), const Greet('later'));
      final worker = QueueWorker(Queue.manager);
      expect(await worker.run(const WorkerOptions(maxJobs: 2)), 0);
      expect(worker.processed, 2);
      expect(await Queue.size(), 2);

      final restarting = QueueWorker(Queue.manager);
      final run = restarting.run(
        const WorkerOptions(sleep: Duration(milliseconds: 20)),
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await Queue.manager.restart();
      expect(await run, 1);
      expect(await Queue.size(), 1, reason: 'the delayed job stays');

      final fake = Queue.fake();
      await Queue.dispatch(const Greet('faked')).onQueue('x');
      fake.assertPushed<Greet>((g) => g.name == 'faked');
      fake.assertPushedOn<Greet>('x');
      fake.assertNotPushed<Slow>();
      expect(() => fake.assertNothingPushed(), throwsStateError);
      Queue.restore();
    });
  });
}
