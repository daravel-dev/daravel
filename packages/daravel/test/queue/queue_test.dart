import 'dart:convert';
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
  List<String> get tags => ['user:$name', 'greetings'];

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

/// Takes longer than its timeout and does not fail on it: released for
/// another attempt while its future still runs.
final class Stale extends Job {
  const Stale({required this.drop});
  final bool drop;
  @override
  String get jobName => 'stale';
  @override
  int get tries => 3;
  @override
  bool get deleteWhenMissingModels => drop;
  @override
  Map<String, Object?> toJson() => {'drop': drop};
  @override
  Future<void> handle(JobContext ctx) async {
    throw ModelNotFoundException(r'App\Models\User', const [7]);
  }
}

final class Lingering extends Job {
  const Lingering();
  @override
  String get jobName => 'lingering';
  @override
  int get tries => 3;
  @override
  Duration get timeout => const Duration(milliseconds: 20);
  @override
  bool get failOnTimeout => false;
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) =>
      Future<void>.delayed(const Duration(milliseconds: 150));
}

final List<JobDefinition> definitions = [
  JobDefinition('greet', Greet.fromJson),
  JobDefinition('lingering', (_) => const Lingering()),
  JobDefinition('stale', (j) => Stale(drop: j['drop']! as bool)),
  JobDefinition('slow', (_) => const Slow()),
  JobDefinition('exclusive', (j) => Exclusive(j['key']! as String)),
  JobDefinition('controlled', (j) => Controlled(j['action']! as String)),
];

void main() {
  Application? app;

  Future<void> boot(String connection) async {
    log.clear();
    app =
        Application.configure(
              // Its own directory: queue:pause signals live in the file store.
              basePath: Directory.systemTemp
                  .createTempSync('daravel_queue_')
                  .path,
            )
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

  group('extension hooks (Horizon-style tooling)', () {
    test('job tags are stored in the payload', () {
      final payload = JobPayload.forJob(const Greet('ana'));
      expect(payload.tags, ['user:ana', 'greetings']);
      expect(payload.toJson()['tags'], ['user:ana', 'greetings']);
      expect(JobPayload.decode(payload.encode()).tags, payload.tags);
    });

    for (final connection in ['memory', 'database']) {
      test('oldestWait on $connection', () async {
        await boot(connection);
        await app!.run(() async {
          final driver = Queue.connection();
          expect(await driver.oldestWait('default'), isNull);
          await Queue.push(const Greet('ana'));
          final wait = await driver.oldestWait('default');
          expect(wait, isNotNull);
          expect(wait!.inSeconds, lessThan(5));
          await Queue.later(
            const Duration(hours: 1),
            const Greet('bo'),
            queue: 'later',
          );
          expect(
            await driver.oldestWait('later'),
            isNull,
            reason: 'delayed jobs are not waiting yet',
          );
        });
      });
    }

    test(
      'queue:pause stops every worker taking jobs until continued',
      () async {
        await boot('database');
        await app!.run(() async {
          await Queue.push(const Greet('ana'));
          await Queue.manager.pause('default');
          expect(await Queue.manager.isPaused('default'), isTrue);
          await QueueWorker(Queue.manager)
              .run(const WorkerOptions(stopWhenEmpty: true));
          expect(log, isEmpty);
          expect(await Queue.size(), 1);

          await Queue.manager.resume('default');
          await QueueWorker(Queue.manager)
              .run(const WorkerOptions(stopWhenEmpty: true));
          expect(log, ['greet:ana:1']);
        });
      },
    );

    test('a paused worker takes nothing until resumed', () async {
      await boot('memory');
      await app!.run(() async {
        await Queue.push(const Greet('ana'));
        final worker = QueueWorker(Queue.manager)..pause();
        expect(worker.paused, isTrue);
        final driver = Queue.connection();
        expect(await worker.runNextJob(driver, const WorkerOptions()), isFalse);
        worker.resume();
        expect(await worker.runNextJob(driver, const WorkerOptions()), isTrue);
        expect(log, ['greet:ana:1']);
      });
    });
  });

  group('sharing the jobs table with Laravel', () {
    // Illuminate\Queue\Queue::createObjectPayload (Laravel 12), as stored by
    // `SendWelcomeEmail::dispatch($user)` in a Laravel app.
    final laravelPayload = jsonEncode({
      'uuid': '5f1c7a2e-1e2a-4c1d-9a5e-0d9b3f6c2a11',
      'displayName': r'App\Jobs\SendWelcomeEmail',
      'job': r'Illuminate\Queue\CallQueuedHandler@call',
      'maxTries': null,
      'maxExceptions': null,
      'failOnTimeout': false,
      'backoff': '1,5,10',
      'timeout': null,
      'retryUntil': null,
      'data': {
        'commandName': r'App\Jobs\SendWelcomeEmail',
        'command': r'O:25:"App\Jobs\SendWelcomeEmail":1:{s:4:"user";i:42;}',
        'batchId': null,
      },
      'createdAt': 1792832400,
    });

    test('recognises Laravel payloads and nothing else', () {
      expect(DatabaseQueue.isForeignPayload(laravelPayload), isTrue);
      expect(DatabaseQueue.isForeignPayload('not json'), isTrue);
      expect(
        DatabaseQueue.isForeignPayload(
          JobPayload.forJob(const Greet('ana')).encode(),
        ),
        isFalse,
      );
    });

    test(
      'Laravel jobs are skipped untouched; Daravel jobs behind them run',
      () async {
        await boot('database');
        await app!.run(() async {
          final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          // Twenty Laravel jobs queued first, on the same queue name.
          for (var i = 0; i < 20; i++) {
            await DB.table('jobs').insert({
              'queue': 'default',
              'payload': laravelPayload,
              'attempts': 0,
              'reserved_at': null,
              'available_at': now,
              'created_at': now,
            });
          }
          await Queue.push(const Greet('ana'));
          await QueueWorker(Queue.manager)
              .run(const WorkerOptions(stopWhenEmpty: true));

          expect(log, ['greet:ana:1'], reason: 'the Daravel job ran');
          final laravel = await DB
              .table('jobs')
              .where('payload', laravelPayload)
              .get();
          expect(laravel, hasLength(20), reason: 'Laravel jobs stay queued');
          expect(
            laravel.every(
              (r) => r['attempts'] == 0 && r['reserved_at'] == null,
            ),
            isTrue,
            reason: 'never reserved, attempts untouched',
          );
          expect(await Queue.manager.processor.failedJobs.all(), isEmpty);
        });
      },
    );
  });

  test('a missing model drops the job, or fails it at once', () async {
    await boot('sync');
    await app!.run(() async {
      await Queue.push(const Stale(drop: true));
      expect(await Queue.manager.processor.failedJobs.all(), isEmpty);
      await Queue.push(const Stale(drop: false));
      expect(await Queue.manager.processor.failedJobs.all(), hasLength(1));
    });
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
          await Queue.dispatch(const Greet('cy', failTimes: 1))
              .onQueue('emails');
          await Queue.dispatch(const Greet('di', failTimes: 9));
          expect(await driver.size('emails'), 1);
          expect(await driver.size('default'), 1);
          final events = Event.fake();

          // First pass: both fail once and are released with 1s backoff.
          // Domain time stands still, so a slow runner cannot let the
          // backoff run out during the pass and process a job twice.
          Clock.freeze();
          addTearDown(Clock.restore);
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
          Clock.travel(const Duration(milliseconds: 1100));
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
          Clock.travel(const Duration(milliseconds: 5100));
          await QueueWorker(manager)
              .run(const WorkerOptions(stopWhenEmpty: true));
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
        await QueueWorker(Queue.manager)
            .run(const WorkerOptions(stopWhenEmpty: true));
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
      await QueueWorker(Queue.manager)
          .run(const WorkerOptions(stopWhenEmpty: true));
      expect(await Queue.push(const Greet('ed', unique: 'ed')), isNotNull);
    });
  });

  test('job middleware and context controls (release/delete/fail)', () async {
    await boot('memory');
    await app!.run(() async {
      final driver = Queue.connection();
      final lock = Cache.store('process')
          .lock('overlap:exclusive:k1', owner: 'someone');
      expect(await lock.acquire(), isTrue);
      await Queue.push(const Exclusive('k1'));
      await Queue.push(const Exclusive('k2'));
      await QueueWorker(Queue.manager)
          .run(const WorkerOptions(stopWhenEmpty: true));
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
      await QueueWorker(Queue.manager)
          .run(const WorkerOptions(stopWhenEmpty: true));
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

  test(
    'a Daravel-shaped payload that does not decode goes to failed_jobs',
    () async {
      await boot('database');
      await app!.run(() async {
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        // Daravel-shaped (not skipped as foreign), but `backoff` is not a
        // list of seconds: decoding threw out of pop(), the worker died, and
        // the row came back after retry_after to kill the next one.
        await DB.table('jobs').insert({
          'queue': 'default',
          'payload':
              '{"uuid":"u1","job":"greet","displayName":"greet",'
              '"data":{"name":"x"},"backoff":[null],"createdAt":$now}',
          'attempts': 0,
          'reserved_at': null,
          'available_at': now,
          'created_at': now,
        });
        await Queue.push(const Greet('after'));
        final code = await QueueWorker(Queue.manager)
            .run(const WorkerOptions(stopWhenEmpty: true));
        expect(code, 0);
        expect(log, ['greet:after:1'], reason: 'the worker went on');
        expect(await DB.table('jobs').count(), 0);
        final failed = await Queue.manager.processor.failedJobs.all();
        expect(failed, hasLength(1));
        expect(failed.single.payload, contains('"backoff":[null]'));
        expect(failed.single.exception, contains('does not decode'));
      });
    },
  );

  test(
    'a job whose fromJson throws fails instead of killing the worker',
    () async {
      await boot('database');
      await app!.run(() async {
        // `exclusive` needs a `key`; a payload without one (another release
        // wrote it) made registry.make throw out of the processor.
        final payload = JobPayload.forJob(const Exclusive('k'))
            .encode()
            .replaceFirst('"key":"k"', '"key":null');
        final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        await DB.table('jobs').insert({
          'queue': 'default',
          'payload': payload,
          'attempts': 0,
          'reserved_at': null,
          'available_at': now,
          'created_at': now,
        });
        final code = await QueueWorker(Queue.manager)
            .run(const WorkerOptions(stopWhenEmpty: true));
        expect(code, 0);
        expect(await DB.table('jobs').count(), 0);
        expect(await Queue.manager.processor.failedJobs.all(), hasLength(1));
      });
    },
  );

  test(
    'a job released after a timeout stops the worker for a restart',
    () async {
      await boot('database');
      await app!.run(() async {
        // Lingering outlives its 20 ms timeout, does not fail on it and
        // allows 3 tries: attempt 1 is released while its future still runs,
        // so the worker must not start attempt 2 next to it; it stops with 1
        // (restart me) and the job stays queued for the next worker.
        await Queue.push(const Lingering());
        final worker = QueueWorker(Queue.manager);
        final code = await worker.run(const WorkerOptions());
        expect(code, 1, reason: 'a restart, like queue:restart');
        expect(Queue.manager.processor.timedOutAndReleased, 1);
        final rows = await DB.table('jobs').get();
        expect(rows, hasLength(1), reason: 'released for the next worker');
        expect(await Queue.manager.processor.failedJobs.all(), isEmpty);
      });
    },
  );

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
