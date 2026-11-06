// Issue #158: abandoned handlers, retry_after, releases against tries,
// maxExceptions and un-awaited dispatches.
import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

final List<String> log = <String>[];

/// Completed by a test to let a parked handler go on.
Completer<void> gate = Completer<void>();

/// How the transaction a [LateWriter] handler started ended: `committed`
/// or its error (handed over as a value: errors do not cross into the
/// test zone from the job zone).
Completer<Object> lateOutcome = Completer<Object>();

/// Times out (failOnTimeout) inside a transaction that only gets to insert
/// once the test opens [gate], long after the job was recorded as failed.
final class LateWriter extends Job {
  const LateWriter();
  @override
  String get jobName => 'late-writer';
  @override
  Duration get timeout => const Duration(milliseconds: 10);
  @override
  bool get failOnTimeout => true;
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) {
    final transaction = DB.transaction(() async {
      await gate.future;
      await DB.table('notes').insert({'body': 'late'});
    });
    unawaited(
      transaction.then(
        (_) => lateOutcome.complete('committed'),
        onError: (Object error) => lateOutcome.complete(error),
      ),
    );
    return transaction;
  }
}

/// Attempt 1 leaves an asynchronous error uncaught, then waits for [gate].
final class FireAndForget extends Job {
  const FireAndForget();
  @override
  String get jobName => 'faf';
  @override
  int get tries => 3;
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {
    log.add('start:${ctx.attempt}');
    if (ctx.attempt == 1) {
      unawaited(Future<void>(() => throw StateError('fire and forget')));
      await gate.future;
    }
    log.add('end:${ctx.attempt}');
  }
}

/// Released by `WithoutOverlapping` while the test holds its lock.
final class Blocked extends Job {
  const Blocked();
  @override
  String get jobName => 'blocked';
  @override
  int get tries => 2;
  @override
  List<JobMiddleware> get middleware => const [WithoutOverlapping('k')];
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async => log.add('blocked:ran');
}

/// Always throws; may be tried 10 times but throw only twice.
final class Throwing extends Job {
  const Throwing();
  @override
  String get jobName => 'throwing';
  @override
  int get tries => 10;
  @override
  int? get maxExceptions => 2;
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {
    log.add('throwing:${ctx.attempt}');
    throw StateError('always');
  }
}

/// Retried for a minute after its push.
final class Deadline extends Job {
  const Deadline();
  @override
  String get jobName => 'deadline';
  @override
  Duration? get retryUntil => const Duration(minutes: 1);
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async => log.add('deadline:ran');
}

/// Runs for two minutes at most: longer than a small retry_after.
final class Long extends Job {
  const Long();
  @override
  String get jobName => 'long';
  @override
  Duration get timeout => const Duration(minutes: 2);
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {
    log.add('long:start');
    await gate.future;
  }
}

final class Plain extends Job {
  const Plain(this.name);
  final String name;
  @override
  String get jobName => 'plain';
  @override
  Map<String, Object?> toJson() => {'name': name};
  @override
  Future<void> handle(JobContext ctx) async => log.add('plain:$name');
}

/// Unique and debounced at once: its push throws.
final class Impossible extends Job {
  const Impossible();
  @override
  String get jobName => 'impossible';
  @override
  String? get uniqueId => 'x';
  @override
  Duration? get debounceFor => const Duration(minutes: 1);
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {}
}

/// A memory queue that reserves for [retryAfter] and counts [touch]es.
final class TouchCounting implements ReservingQueueDriver {
  TouchCounting(this.inner);
  final MemoryQueue inner;
  int touches = 0;
  @override
  Duration get retryAfter => const Duration(milliseconds: 20);
  @override
  Future<void> touch(QueuedJob job) async => touches++;
  @override
  String get name => 'touching';
  @override
  StateScope get scope => inner.scope;
  @override
  Future<Object> push(
    JobPayload payload, {
    required String queue,
    Duration? delay,
  }) => inner.push(payload, queue: queue, delay: delay);
  @override
  Future<QueuedJob?> pop(String queue) => inner.pop(queue);
  @override
  Future<void> release(QueuedJob job, Duration delay) =>
      inner.release(job, delay);
  @override
  Future<void> delete(QueuedJob job) => inner.delete(job);
  @override
  Future<int> size(String queue) => inner.size(queue);
  @override
  Future<Duration?> oldestWait(String queue) => inner.oldestWait(queue);
  @override
  Future<int> clear(String queue) => inner.clear(queue);
}

final List<JobDefinition> definitions = [
  JobDefinition('late-writer', (_) => const LateWriter()),
  JobDefinition('faf', (_) => const FireAndForget()),
  JobDefinition('blocked', (_) => const Blocked()),
  JobDefinition('throwing', (_) => const Throwing()),
  JobDefinition('deadline', (_) => const Deadline()),
  JobDefinition('long', (_) => const Long()),
  JobDefinition('plain', (j) => Plain(j['name']! as String)),
  JobDefinition('impossible', (_) => const Impossible()),
];

void main() {
  Application? app;

  Future<void> boot(String connection, [Map<String, String> env = const {}]) {
    log.clear();
    gate = Completer<void>();
    lateOutcome = Completer<Object>();
    app =
        Application.configure(
              basePath: Directory.systemTemp
                  .createTempSync('daravel_attempts_')
                  .path,
            )
            .withEnv({
              'APP_ENV': 'testing',
              'DB_DATABASE': ':memory:',
              'QUEUE_CONNECTION': connection,
              ...env,
            })
            .withMigrations(const [CreateJobsTable(), CreateCacheTable()])
            .withJobs(definitions)
            .create();
    return app!.run(() async {
      await App.make<Migrator>().run();
      await Schema.create('notes', (table) => table.string('body'));
    });
  }

  tearDown(() async {
    if (!gate.isCompleted) {
      gate.complete();
    }
    await app?.shutdown();
    app = null;
  });

  Future<List<FailedJob>> failedJobs() =>
      Queue.manager.processor.failedJobs.all();

  test('a timed-out handler cannot commit after its job failed', () async {
    await boot('memory');
    await app!.run(() async {
      await Queue.push(const LateWriter());
      await QueueWorker(Queue.manager)
          .run(const WorkerOptions(stopWhenEmpty: true));
      expect(await failedJobs(), hasLength(1));

      gate.complete();
      expect(await lateOutcome.future, isA<OperationCancelledException>());
      expect(await DB.table('notes').count(), 0);
    });
  });

  test('a cancelled token refuses to start or commit a transaction', () async {
    await boot('memory');
    await app!.run(() async {
      final token = CancellationToken();
      await token.run(
        () => DB.transaction(() async {
          await DB.table('notes').insert({'body': 'kept'});
        }),
      );
      await expectLater(
        token.run(
          () => DB.transaction(() async {
            await DB.table('notes').insert({'body': 'dropped'});
            token.cancel('given up');
          }),
        ),
        throwsA(isA<OperationCancelledException>()),
      );
      await expectLater(
        token.run(() => DB.transaction(() async => log.add('ran'))),
        throwsA(isA<OperationCancelledException>()),
      );
      expect(log, isEmpty);
      expect(await DB.table('notes').pluck('body'), ['kept']);
    });
  });

  test(
    'a stray async error fails the attempt only after the handler returns',
    () async {
      await boot('memory');
      await app!.run(() async {
        await Queue.push(const FireAndForget());
        final worker = QueueWorker(Queue.manager);
        final done = worker.run(const WorkerOptions(stopWhenEmpty: true));
        for (var i = 0; i < 50 && !log.contains('start:1'); i++) {
          await Future<void>.delayed(Duration.zero);
        }
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(Duration.zero);
        }
        expect(log, ['start:1'], reason: 'attempt 2 waits for attempt 1');
        expect(await Queue.size(), 1);

        gate.complete();
        expect(await done, 0);
        expect(log, ['start:1', 'end:1', 'start:2', 'end:2']);
        expect(Queue.manager.processor.timedOutAndReleased, 0);
      });
    },
  );

  test('releases count against tries (MaxAttemptsExceeded)', () async {
    await boot('memory');
    await app!.run(() async {
      final lock = Cache.store(
        app!.config.section<QueueConfig>().uniqueLockStore,
      ).lock('overlap:blocked:k', ttl: const Duration(minutes: 5));
      expect(await lock.acquire(), isTrue);
      await Queue.push(const Blocked());
      await QueueWorker(Queue.manager)
          .run(const WorkerOptions(stopWhenEmpty: true));
      expect(log, isEmpty);
      expect(await Queue.size(), 0);
      final failed = await failedJobs();
      expect(failed, hasLength(1));
      expect(failed.single.exception, contains('MaxAttemptsExceeded'));
      expect(failed.single.exception, contains('(3 attempts)'));
    });
  });

  test('maxExceptions fails a job before its tries run out', () async {
    await boot('memory');
    await app!.run(() async {
      await Queue.push(const Throwing());
      await QueueWorker(Queue.manager)
          .run(const WorkerOptions(stopWhenEmpty: true));
      expect(log, ['throwing:1', 'throwing:2']);
      expect(await failedJobs(), hasLength(1));
    });
  });

  test('a job reserved after its retryUntil fails without running', () async {
    await boot('memory');
    freezeTime();
    await app!.run(() async {
      await Queue.push(const Deadline());
      travel(const Duration(minutes: 2));
      await QueueWorker(Queue.manager)
          .run(const WorkerOptions(stopWhenEmpty: true));
      expect(log, isEmpty);
      expect(await failedJobs(), hasLength(1));
    });
  });

  test('a job timeout not below retry_after is warned about once', () async {
    await boot('database', {'QUEUE_RETRY_AFTER': '60s'});
    await app!.run(() async {
      final spy = Log.spy();
      gate.complete();
      await Queue.push(const Long());
      await Queue.push(const Long());
      await QueueWorker(Queue.manager)
          .run(const WorkerOptions(stopWhenEmpty: true));
      expect(log, ['long:start', 'long:start']);
      expect(spy.matching(LogLevel.warning, 'retry_after'), hasLength(1));

      await QueueWorker(Queue.manager, logger: Log.logger).run(
        const WorkerOptions(
          stopWhenEmpty: true,
          timeout: Duration(seconds: 90),
        ),
      );
      expect(spy.matching(LogLevel.warning, '--timeout=90'), hasLength(1));
    });
  });

  test('the worker keeps a running job reserved', () async {
    await boot('memory');
    await app!.run(() async {
      final driver = TouchCounting(MemoryQueue());
      Queue.manager.extend('touching', () => driver);
      await Queue.push(const Long(), connection: 'touching');
      final done = QueueWorker(
        Queue.manager,
      ).run(const WorkerOptions(connection: 'touching', stopWhenEmpty: true));
      for (var i = 0; i < 200 && driver.touches < 2; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(driver.touches, greaterThanOrEqualTo(2));
      gate.complete();
      await done;
      final after = driver.touches;
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(driver.touches, after, reason: 'stops with the job');
    });
  });

  test('DatabaseQueue.touch extends only its own reservation', () async {
    await boot('database');
    final start = freezeTime();
    await app!.run(() async {
      final driver = Queue.connection() as DatabaseQueue;
      await Queue.push(const Plain('a'));
      final first = (await driver.pop('default'))!;
      Future<int> reserved() async =>
          ((await DB.table('jobs').first())!['reserved_at']! as num).toInt();
      final popped = await reserved();
      expect(popped, start.millisecondsSinceEpoch ~/ 1000);

      travel(const Duration(seconds: 50));
      await driver.touch(first);
      expect(await reserved(), popped + 50);

      // Past retry_after another worker reserves it (attempts 2): the first
      // worker's heartbeat must not extend that reservation.
      travel(const Duration(seconds: 91));
      final second = (await driver.pop('default'))!;
      expect(second.attempts, 2);
      final retaken = await reserved();
      travel(const Duration(seconds: 10));
      await driver.touch(first);
      expect(await reserved(), retaken);
      await driver.touch(second);
      expect(await reserved(), retaken + 10);
    });
  });

  group('dispatch without await', () {
    test('is pushed, with the setters chained on it', () async {
      await boot('memory');
      await app!.run(() async {
        void dispatchAndForget() {
          // ignore: unawaited_futures
          Queue.dispatch(const Plain('a'));
          // ignore: unawaited_futures
          Queue.dispatch(const Plain('b')).onQueue('high');
        }

        dispatchAndForget();
        await Future<void>.delayed(Duration.zero);
        expect(await Queue.size('default'), 1);
        expect(await Queue.size('high'), 1);
      });
    });

    test('pushes once when awaited, and refuses late setters', () async {
      await boot('memory');
      await app!.run(() async {
        final dispatch = Queue.dispatch(const Plain('a'));
        expect(await dispatch, isNotNull);
        await Future<void>.delayed(Duration.zero);
        expect(await Queue.size(), 1);
        expect(() => dispatch.onQueue('late'), throwsStateError);
      });
    });

    test('a failed push nobody awaits is logged', () async {
      await boot('memory');
      await app!.run(() async {
        final spy = Log.spy();
        // ignore: unawaited_futures
        Queue.dispatch(const Impossible());
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);
        spy.assertLogged(LogLevel.error, 'Dispatching Impossible failed');

        await expectLater(Queue.dispatch(const Impossible()), throwsStateError);
      });
    });
  });
}
