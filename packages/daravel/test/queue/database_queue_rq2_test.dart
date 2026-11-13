import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

import '../database/support/test_databases.dart';

final class Ping extends Job {
  const Ping([this.data = const {}]);

  final Map<String, Object?> data;

  @override
  String get jobName => 'ping';

  @override
  Map<String, Object?> toJson() => data;

  @override
  Future<void> handle(JobContext context) async {}
}

final class Fails extends Job {
  const Fails();

  @override
  String get jobName => 'fails';

  @override
  int get tries => 1;

  @override
  Map<String, Object?> toJson() => const {};

  @override
  Future<void> handle(JobContext context) async => throw StateError('boom');

  /// How many times a `failed()` hook ran.
  static int hooks = 0;

  @override
  Future<void> failed(Object error, StackTrace stackTrace) async => hooks++;
}

/// A Daravel job whose `data` holds a string `command`, as Laravel's
/// serialized command does.
final class Commander extends Job {
  const Commander(this.jobName);

  @override
  final String jobName;

  @override
  Map<String, Object?> toJson() => const {'command': 'report:send'};

  @override
  Future<void> handle(JobContext context) async {}
}

/// A failed-job provider whose `log` fails.
final class _FailingProvider implements FailedJobProvider {
  @override
  Future<Object> log({
    required String connection,
    required String queue,
    required String payload,
    required String exception,
  }) async => throw StateError('failed_jobs is down');

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// A provider (another connection) that finds the job's uuid already in
/// `failed_jobs`: another worker recorded it.
final class _RecordedElsewhere implements FailedJobProvider {
  @override
  Future<Object> log({
    required String connection,
    required String queue,
    required String payload,
    required String exception,
  }) async => throw UniqueConstraintViolationException(
    'other',
    'insert into failed_jobs',
    const [],
    StateError('duplicate uuid'),
  );

  @override
  Object? noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}

/// The Laravel 13.40.0 payloads in `fixtures/laravel_job_payloads.json`,
/// pushed by Laravel's own database queue (class job, legacy string job,
/// `Class@method` job, `pushRaw` JSON, `pushRaw` text).
List<String> laravelPayloads() {
  for (final path in [
    'test/queue/fixtures/laravel_job_payloads.json',
    '../daravel/test/queue/fixtures/laravel_job_payloads.json',
  ]) {
    final file = File(path);
    if (file.existsSync()) {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
      return (json['payloads']! as List<Object?>).cast<String>();
    }
  }
  throw StateError('laravel_job_payloads.json not found');
}

/// RQ-2: the database queue's release and delete act only on the worker's
/// own reservation; a registered job is never taken for Laravel's; foreign
/// rows do not hide Daravel jobs (a cursor, and a narrow query below it);
/// a failed job is recorded before it is removed; `attempts` stops at 255.
void databaseQueueRq2Tests(DatabaseOpener open) {
  late DatabaseManager db;
  const table = 'rq2_jobs';
  const failedTable = 'rq2_failed_jobs';
  var now = DateTime.utc(2027, 1, 1);
  late MemoryHandler logs;

  setUp(() async {
    db = open();
    now = DateTime.utc(2027, 1, 1);
    logs = MemoryHandler();
    final schema = await freshSchema(db, [table, failedTable]);
    await schema.create(table, (t) {
      t.id();
      t.string('queue').index();
      t.longText('payload');
      t.tinyInteger('attempts').unsigned();
      t.unsignedInteger('reserved_at').nullable();
      t.unsignedInteger('available_at');
      t.unsignedInteger('created_at');
    });
    await schema.create(failedTable, (t) {
      t.id();
      t.string('uuid').unique();
      t.text('connection');
      t.text('queue');
      t.longText('payload');
      t.longText('exception');
      t.timestamp('failed_at').useCurrent();
    });
  });
  tearDown(() => db.closeAll());

  DatabaseQueue queue({
    Duration retryAfter = const Duration(seconds: 10),
    void Function(String queue, Object id, String handler)? onForeignJob,
  }) => DatabaseQueue(
    db,
    table: table,
    retryAfter: retryAfter,
    clock: () => now,
    logger: Logger(handlers: [logs]),
    isKnownJob: (name) => name == 'ping' || name == 'fails',
    onForeignJob: onForeignJob,
  );

  int warnings() => logs.matching(LogLevel.warning, 'ran past').length;
  Future<int> rows() => db.table(table).count();

  /// A pops; its reservation runs out; B pops the same job.
  Future<(DatabaseQueue, QueuedJob, QueuedJob)> taken() async {
    final q = queue();
    await q.push(JobPayload.forJob(const Ping()), queue: 'default');
    final a = (await q.pop('default'))!;
    now = now.add(const Duration(seconds: 11));
    final b = (await q.pop('default'))!;
    expect(b.id, a.id);
    expect(b.attempts, a.attempts + 1);
    return (q, a, b);
  }

  group('ownership', () {
    test('the first worker deletes: the second keeps the job', () async {
      final (q, a, b) = await taken();
      await q.delete(a);
      expect(await rows(), 1, reason: "B's job is still there");
      expect(warnings(), 1);
      await q.delete(b);
      expect(await rows(), 0);
    });

    test('the first worker releases: the second keeps its reservation; no '
        'third worker runs it', () async {
      final (q, a, b) = await taken();
      await q.release(a, Duration.zero);
      expect(await q.pop('default'), isNull, reason: 'no C');
      await q.delete(b);
      expect(await rows(), 0);
      expect(warnings(), 1);
    });

    test('a release after the job was deleted does nothing', () async {
      final (q, a, b) = await taken();
      await q.delete(b);
      await q.release(a, Duration.zero);
      expect(await rows(), 0);
      expect(await q.pop('default'), isNull);
    });

    test('a waiting job whose attempts match is deleted (daravel_horizon '
        'quarantines a reclaimed job this way)', () async {
      final q = queue();
      await q.push(JobPayload.forJob(const Ping()), queue: 'default');
      final job = (await q.pop('default'))!;
      expect(await q.reclaim('default', job.id), isTrue);
      final view = (await q.pending('default')).single;
      await q.delete(
        QueuedJob(
          id: view.id,
          queue: 'default',
          payload: JobPayload.decode(view.payload),
          attempts: view.attempts,
          raw: view.payload,
        ),
      );
      expect(await rows(), 0);
      expect(warnings(), 0);
    });

    test('releasing twice queues it once, and warns once', () async {
      final q = queue();
      await q.push(JobPayload.forJob(const Ping()), queue: 'default');
      final job = (await q.pop('default'))!;
      await q.release(job, Duration.zero);
      await q.release(job, Duration.zero);
      expect(await rows(), 1);
      final again = (await q.pop('default'))!;
      expect(again.id, job.id);
      expect(await q.pop('default'), isNull);
      expect(warnings(), 1);
    });
  });

  group('foreign rows', () {
    test('every Laravel payload is foreign; a registered job with a string '
        '`command` is not', () {
      bool known(String name) => name == 'ping';
      for (final raw in laravelPayloads()) {
        expect(
          DatabaseQueue.isForeignPayload(raw, isKnownJob: known),
          isTrue,
          reason: raw,
        );
      }
      final registered = JobPayload.forJob(const Commander('ping')).encode();
      expect(DatabaseQueue.isForeignPayload(registered), isTrue);
      expect(
        DatabaseQueue.isForeignPayload(registered, isKnownJob: known),
        isFalse,
      );
    });

    test('a registered job with a string `command` is popped; an '
        'unregistered one is skipped as foreign, for ever', () async {
      final q = queue();
      await q.push(
        JobPayload.forJob(const Commander('ping')),
        queue: 'default',
      );
      await q.push(
        JobPayload.forJob(const Commander('unregistered')),
        queue: 'default',
      );
      final first = (await q.pop('default'))!;
      expect(first.payload.jobName, 'ping');
      await q.delete(first);
      expect(await q.pop('default'), isNull);
      now = now.add(const Duration(minutes: 5));
      expect(await q.pop('default'), isNull, reason: 'after a cursor reset');
      expect(await rows(), 1, reason: 'left for another runtime');
    });

    Future<void> foreign(
      int count, {
      String queueName = 'default',
      Duration delay = Duration.zero,
    }) async {
      final raw = laravelPayloads().first;
      final at = now.add(delay).millisecondsSinceEpoch ~/ 1000;
      for (var i = 0; i < count; i += 500) {
        await db.table(table).insert([
          for (var j = i; j < i + 500 && j < count; j++)
            {
              'queue': queueName,
              'payload': raw,
              'attempts': 0,
              'reserved_at': null,
              'available_at': at,
              'created_at': at,
            },
        ]);
      }
    }

    test('a job behind 2 000 foreign rows is reached in a few pops, and '
        'each foreign row is reported once', () async {
      var reported = 0;
      final q = queue(onForeignJob: (_, _, _) => reported++);
      await foreign(2000);
      await q.push(JobPayload.forJob(const Ping()), queue: 'default');
      var pops = 0;
      QueuedJob? job;
      while (job == null && pops < 10) {
        job = await q.pop('default');
        pops++;
      }
      expect(job, isNotNull, reason: 'after $pops pops');
      expect(pops, 1, reason: 'one pop reads up to 8 growing batches');
      expect(reported, 2000);
      now = now.add(const Duration(seconds: 11));
      await q.pop('default');
      expect(reported, 2000, reason: 'not again after the cursor reset');
    });

    test('below the cursor: a delayed job falling due is popped at once, '
        'not after retry_after', () async {
      final q = queue(retryAfter: const Duration(seconds: 90));
      await q.push(
        JobPayload.forJob(const Ping()),
        queue: 'default',
        delay: const Duration(seconds: 30),
      );
      await foreign(300);
      expect(await q.pop('default'), isNull);
      now = now.add(const Duration(seconds: 31));
      final job = await q.pop('default');
      expect(job, isNotNull);
    });

    test('below the cursor: a job another process releases is popped at '
        'once', () async {
      final q = queue(retryAfter: const Duration(seconds: 90));
      final other = queue(retryAfter: const Duration(seconds: 90));
      await q.push(JobPayload.forJob(const Ping()), queue: 'default');
      final held = (await other.pop('default'))!;
      await foreign(300);
      expect(await q.pop('default'), isNull);
      now = now.add(const Duration(seconds: 2));
      await other.release(held, Duration.zero);
      final job = await q.pop('default');
      expect(job?.id, held.id);
    });

    test('below the cursor: a stale reservation is popped once it is '
        'stale', () async {
      final q = queue(retryAfter: const Duration(seconds: 90));
      final crashed = queue(retryAfter: const Duration(seconds: 90));
      await q.push(JobPayload.forJob(const Ping()), queue: 'default');
      final held = (await crashed.pop('default'))!;
      await foreign(300);
      now = now.add(const Duration(seconds: 30));
      expect(await q.pop('default'), isNull);
      now = now.add(const Duration(seconds: 61));
      final job = await q.pop('default');
      expect(job?.id, held.id);
      expect(job?.attempts, 2);
    });

    test(
      'below the cursor: more than a page of foreign rows falling due '
      'ahead of a Daravel job hide nothing (read a page at a time)',
      () async {
        final q = queue(retryAfter: const Duration(seconds: 90));
        // 1 200 Laravel jobs and then one Daravel job, all due in 30 s, below
        // where the cursor will be; then rows due now to move the cursor.
        await foreign(1200, delay: const Duration(seconds: 30));
        await q.push(
          JobPayload.forJob(const Ping()),
          queue: 'default',
          delay: const Duration(seconds: 30),
        );
        await foreign(300);
        expect(await q.pop('default'), isNull);
        now = now.add(const Duration(seconds: 31));
        final job = await q.pop('default');
        expect(job, isNotNull, reason: 'behind 1 200 rows in the window');
        expect(job!.payload.jobName, 'ping');
      },
    );

    test(
      'below the cursor: a job taken back by reclaim is popped at once',
      () async {
        final q = queue(retryAfter: const Duration(seconds: 90));
        final other = queue(retryAfter: const Duration(seconds: 90));
        await q.push(JobPayload.forJob(const Ping()), queue: 'default');
        final held = (await other.pop('default'))!;
        // The job was pushed well before the cursor is set: its
        // available_at is outside the window below the cursor.
        now = now.add(const Duration(seconds: 20));
        await foreign(300);
        expect(await q.pop('default'), isNull);
        now = now.add(const Duration(seconds: 2));
        expect(await other.reclaim('default', held.id), isTrue);
        final job = await q.pop('default');
        expect(job?.id, held.id, reason: 'not after retry_after');
      },
    );

    test('ids that are not integers: no cursor, no id filter; the job is '
        'popped', () async {
      const uuidTable = 'rq2_jobs_uuid';
      final schema = await freshSchema(db, [uuidTable]);
      await schema.create(uuidTable, (t) {
        // A real uuid column on PostgreSQL, where `id > 0` is refused.
        t.uuid('id').primary();
        t.string('queue').index();
        t.longText('payload');
        t.tinyInteger('attempts').unsigned();
        t.unsignedInteger('reserved_at').nullable();
        t.unsignedInteger('available_at');
        t.unsignedInteger('created_at');
      });
      final at = now.millisecondsSinceEpoch ~/ 1000;
      final raw = laravelPayloads().first;
      await db.table(uuidTable).insert([
        for (var i = 0; i < 20; i++)
          {
            'id': '00000000-0000-4000-8000-${'$i'.padLeft(12, '0')}',
            'queue': 'default',
            'payload': raw,
            'attempts': 0,
            'available_at': at,
            'created_at': at,
          },
        {
          'id': 'ffffffff-0000-4000-8000-000000000001',
          'queue': 'default',
          'payload': JobPayload.forJob(const Ping()).encode(),
          'attempts': 0,
          'available_at': at,
          'created_at': at,
        },
      ]);
      final q = DatabaseQueue(
        db,
        table: uuidTable,
        clock: () => now,
        isKnownJob: (name) => name == 'ping',
      );
      final job = await q.pop('default');
      expect(
        '${job?.id}'.toLowerCase(),
        'ffffffff-0000-4000-8000-000000000001',
      );
      await q.delete(job!);
      expect(await q.pop('default'), isNull);
      await schema.dropIfExists(uuidTable);
    });
  });

  group('failing a job', () {
    JobProcessor processor(FailedJobProvider failed) => JobProcessor(
      registry: JobRegistry([
        JobDefinition('fails', (_) => const Fails()),
        JobDefinition('ping', (_) => const Ping()),
      ]),
      events: EventDispatcher(),
      failedJobs: failed,
      container: Container(),
    );

    test('recorded before it is removed: a record that fails leaves the '
        'job in the queue', () async {
      final q = queue();
      await q.push(JobPayload.forJob(const Fails()), queue: 'default');
      final job = (await q.pop('default'))!;
      await expectLater(
        processor(_FailingProvider()).process(q, job),
        throwsA(isA<StateError>()),
      );
      expect(await rows(), 1, reason: 'not lost');
    });

    test('on the queue connection: recorded and removed together', () async {
      final q = queue();
      final failed = DatabaseFailedJobProvider(db, table: failedTable);
      await q.push(JobPayload.forJob(const Fails()), queue: 'default');
      final job = (await q.pop('default'))!;
      await processor(failed).process(q, job);
      expect(await rows(), 0);
      expect(await db.table(failedTable).count(), 1);
    });

    test('on the queue connection: a record that fails rolls the removal '
        'back', () async {
      final q = queue();
      final failed = DatabaseFailedJobProvider(db, table: 'rq2_missing');
      await q.push(JobPayload.forJob(const Fails()), queue: 'default');
      final job = (await q.pop('default'))!;
      await expectLater(
        processor(failed).process(q, job),
        throwsA(isA<QueryException>()),
      );
      expect(await rows(), 1, reason: 'not lost');
    });

    for (final sameConnection in [true, false]) {
      test(
        'a worker that lost its job to another does not fail it: no '
        'record, no hook, the job stays the other worker\'s '
        '(${sameConnection ? 'one transaction' : 'another provider'})',
        () async {
          Fails.hooks = 0;
          final q = queue();
          final FailedJobProvider failed = sameConnection
              ? DatabaseFailedJobProvider(db, table: failedTable)
              : MemoryFailedJobProvider();
          await q.push(JobPayload.forJob(const Fails()), queue: 'default');
          final a = (await q.pop('default'))!;
          now = now.add(const Duration(seconds: 11));
          final b = (await q.pop('default'))!;
          expect(b.attempts, 2);

          await processor(failed).process(q, a);
          expect((await failed.all()).length, 0, reason: 'A records nothing');
          expect(Fails.hooks, 0, reason: "A's failed() does not run");
          expect(await rows(), 1);
          expect(
            (await db.table(table).first())!['attempts'],
            2,
            reason: "still B's reservation",
          );

          await processor(failed).process(q, b);
          expect((await failed.all()).length, 1, reason: 'B fails it, once');
          expect(Fails.hooks, 1);
          expect(await rows(), 0);
        },
      );
    }

    test(
      'two reservations at 255 attempts: the second failure finds the '
      "uuid in failed_jobs and is not this worker's (no throw, no hook)",
      () async {
        Fails.hooks = 0;
        final q = queue();
        final failed = DatabaseFailedJobProvider(db, table: failedTable);
        await q.push(JobPayload.forJob(const Fails()), queue: 'default');
        await db.table(table).update({'attempts': 254});
        final a = (await q.pop('default'))!;
        expect(a.attempts, 255);
        expect(a.attemptsExhausted, isFalse);
        now = now.add(const Duration(seconds: 11));
        final b = (await q.pop('default'))!;
        expect(b.attemptsExhausted, isTrue);
        expect(b.attempts, 255, reason: 'the same token as A: (id, 255)');
        await processor(failed).process(q, b);
        await processor(failed).process(q, a);
        expect(await db.table(failedTable).count(), 1);
        expect(
          Fails.hooks,
          1,
          reason: "once, B's (MaxAttemptsExceeded); A was not the owner",
        );
        expect(await rows(), 0);
      },
    );

    test('a record refused for its uuid on another connection: not this '
        "worker's, no throw, no hook, the row stays", () async {
      Fails.hooks = 0;
      final q = queue();
      await q.push(JobPayload.forJob(const Fails()), queue: 'default');
      final job = (await q.pop('default'))!;
      await processor(_RecordedElsewhere()).process(q, job);
      expect(Fails.hooks, 0);
      expect(await rows(), 1, reason: 'left to whoever recorded it');
    });
  });

  group('attempts at 255', () {
    test('a row whose claim fails is passed over, once; a second failure in '
        'a row is thrown (SQLite trigger)', () async {
      final executor = await db.executor();
      if (executor.dialect != SqlDialect.sqlite) {
        return; // The trigger is SQLite's; the logic is the dialect's same.
      }
      final q = queue();
      await q.push(JobPayload.forJob(const Ping()), queue: 'default');
      await q.push(JobPayload.forJob(const Ping()), queue: 'default');
      final first = (await db.table(table).orderBy('id').first())!['id'];
      await executor.execute(
        'CREATE TRIGGER rq2_refuse BEFORE UPDATE ON $table '
        "WHEN OLD.id = $first BEGIN SELECT RAISE(ABORT, 'refused'); END",
        const [],
      );
      final next = (await q.pop('default'))!;
      expect(next.id, isNot(first), reason: 'the row behind it runs');
      expect(logs.matching(LogLevel.warning, 'cannot be reserved').length, 1);
      await executor.execute('DROP TRIGGER rq2_refuse', const []);
      await executor.execute(
        'CREATE TRIGGER rq2_refuse BEFORE UPDATE ON $table '
        "BEGIN SELECT RAISE(ABORT, 'refused'); END",
        const [],
      );
      await q.push(JobPayload.forJob(const Ping()), queue: 'default');
      await expectLater(
        q.pop('default'),
        throwsA(isA<QueryException>()),
        reason: 'every row fails: not the row, the database',
      );
    });

    test('a job that reached 255 attempts is failed without running, and '
        'the job behind it still runs', () async {
      final q = queue();
      final failed = DatabaseFailedJobProvider(db, table: failedTable);
      await q.push(JobPayload.forJob(const Ping()), queue: 'default');
      await q.push(JobPayload.forJob(const Ping()), queue: 'default');
      final first = await db.table(table).orderBy('id').first();
      await db.table(table).where('id', first!['id']).update({'attempts': 255});
      final exhausted = (await q.pop('default'))!;
      expect(exhausted.attemptsExhausted, isTrue);
      expect(exhausted.attempts, 255);
      final outcome = await JobProcessor(
        registry: JobRegistry([JobDefinition('ping', (_) => const Ping())]),
        events: EventDispatcher(),
        failedJobs: failed,
        container: Container(),
      ).process(q, exhausted, tries: 0);
      expect(outcome, JobOutcome.failed);
      expect(await db.table(failedTable).count(), 1);
      final next = (await q.pop('default'))!;
      expect(next.attemptsExhausted, isFalse);
      expect(next.attempts, 1);
    });
  });
}

void main() {
  forEachDatabase(databaseQueueRq2Tests);
}
