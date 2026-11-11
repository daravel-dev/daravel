import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A unique job: one pending dispatch per id.
final class Only extends Job {
  const Only(this.id);

  final String id;

  @override
  String get jobName => 'only';

  @override
  String? get uniqueId => id;

  @override
  Map<String, Object?> toJson() => {'id': id};

  @override
  Future<void> handle(JobContext ctx) async {}
}

/// A debounced job: the last dispatch of a burst owns the key.
final class Settle extends Job {
  const Settle(this.id);

  final String id;

  @override
  String get jobName => 'settle';

  /// Short, so a test can run the job at once.
  @override
  Duration? get debounceFor => const Duration(milliseconds: 1);

  @override
  String get debounceId => id;

  @override
  Map<String, Object?> toJson() => {'id': id};

  @override
  Future<void> handle(JobContext ctx) async => settled.add(id);
}

/// What the [Settle] jobs did.
final List<String> settled = <String>[];

/// G1.5 (b): inside a transaction, a unique job's lock (and a debounced
/// job's owner) is taken at dispatch, given back on rollback, and the push
/// waits for the commit (Laravel's `PendingDispatch::shouldDispatch` and
/// `Queue::enqueueUsing`).
void main() {
  late Application app;
  final pushFailures = <JobPushFailedAfterCommit>[];

  setUp(() async {
    pushFailures.clear();
    app =
        Application.configure(
              basePath: Directory.systemTemp
                  .createTempSync('daravel_unique_')
                  .path,
            )
            .withEnv(const {
              'APP_ENV': 'testing',
              'DB_DATABASE': ':memory:',
              'QUEUE_CONNECTION': 'memory',
            })
            .withJobs([
              JobDefinition('only', (j) => Only(j['id']! as String)),
              JobDefinition('settle', (j) => Settle(j['id']! as String)),
            ])
            .create();
    await app.boot();
    app.container.make<EventDispatcher>().listen<JobPushFailedAfterCommit>(
      pushFailures.add,
    );
  });
  tearDown(() => app.shutdown());

  QueueManager queue() => app.container.make<QueueManager>();
  DatabaseManager db() => app.container.make<DatabaseManager>();
  Future<int> size() => queue().connection('memory').size('default');
  Future<bool> lockFree(String id) async {
    final lock = app.container
        .make<CacheManager>()
        .store('process')
        .lock('unique:only:$id', ttl: const Duration(seconds: 5));
    final free = await lock.acquire();
    if (free) {
      await lock.release();
    }
    return free;
  }

  test('the lock is taken at dispatch: a second dispatch is refused before '
      'the first transaction commits', () async {
    await app.run(() async {
      await db().transaction(() async {
        await queue().push(const Only('a'), afterCommit: true);
        expect(await size(), 0, reason: 'the push waits for the commit');
        expect(await lockFree('a'), isFalse, reason: 'held since dispatch');
        // Another dispatch of the same id, outside this transaction.
        await Zone.root.run(
          () => queue().push(const Only('a'), afterCommit: true),
        );
        expect(await size(), 0, reason: 'refused, not pushed');
      });
      expect(await size(), 1);
    });
  });

  test('a rollback gives the lock back', () async {
    await app.run(() async {
      await expectLater(
        db().transaction(() async {
          await queue().push(const Only('b'), afterCommit: true);
          throw StateError('rolled back');
        }),
        throwsStateError,
      );
      expect(await size(), 0);
      expect(await lockFree('b'), isTrue);
      await queue().push(const Only('b'));
      expect(await size(), 1);
    });
  });

  test('a savepoint rolled back gives back only its own lock', () async {
    await app.run(() async {
      await db().transaction(() async {
        await queue().push(const Only('outer'), afterCommit: true);
        await expectLater(
          db().transaction(() async {
            await queue().push(const Only('inner'), afterCommit: true);
            throw StateError('inner rolled back');
          }),
          throwsStateError,
        );
        expect(await lockFree('inner'), isTrue);
        expect(await lockFree('outer'), isFalse);
      });
      expect(await size(), 1);
    });
  });

  test('two unique jobs, the first push fails after commit: the second is '
      'still pushed, the first lock given back, the caller gets the first '
      'error, counted once', () async {
    await app.run(() async {
      await expectLater(
        db().transaction(() async {
          await queue().push(
            const Only('c1'),
            afterCommit: true,
            connection: 'no-such-connection',
          );
          await queue().push(const Only('c2'), afterCommit: true);
        }),
        throwsA(anything),
      );
      expect(await size(), 1, reason: 'the second was pushed');
      expect(await lockFree('c1'), isTrue, reason: 'given back');
      expect(await lockFree('c2'), isFalse, reason: 'pushed, still pending');
      expect(pushFailures, hasLength(1));
      expect(pushFailures.single.jobName, 'only');
      expect(pushFailures.single.connection, 'no-such-connection');
    });
  });

  /// Runs the queued jobs that are due, a moment after their debounce.
  Future<void> runDue() async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    final worker = QueueWorker(queue());
    final driver = queue().connection('memory');
    while (await worker.runNextJob(driver, const WorkerOptions())) {}
  }

  test('debounce, rollback: the job already queued still runs while the '
      'transaction is open, and nothing is lost', () async {
    settled.clear();
    await app.run(() async {
      // J1 queued, owning the key.
      await queue().push(const Settle('d'));
      await expectLater(
        db().transaction(() async {
          // J2 dispatched inside: the owner does not move yet.
          await queue().push(const Settle('d'), afterCommit: true);
          // J1 falls due while the transaction is open: it is still the
          // owner, so it runs.
          await Zone.root.run(runDue);
          expect(settled, ['d']);
          throw StateError('rolled back');
        }),
        throwsStateError,
      );
      await runDue();
      expect(settled, ['d'], reason: 'the work ran exactly once');
    });
  });

  test('debounce, commit: the job already queued drops itself, the one '
      'pushed at the commit runs', () async {
    settled.clear();
    await app.run(() async {
      await queue().push(const Settle('e'));
      await db().transaction(() async {
        await queue().push(const Settle('e'), afterCommit: true);
      });
      await runDue();
      expect(settled, ['e'], reason: 'J2 ran; J1 dropped itself');
    });
  });

  test('a JobPushFailedAfterCommit listener that throws does not replace '
      "the push's own error", () async {
    app.container.make<EventDispatcher>().listen<JobPushFailedAfterCommit>(
      (_) => throw StateError('listener bug'),
    );
    await app.run(() async {
      await expectLater(
        db().transaction(() async {
          await queue().push(
            const Only('f'),
            afterCommit: true,
            connection: 'no-such-connection',
          );
        }),
        throwsA(isA<ConfigException>()),
      );
    });
  });
}
