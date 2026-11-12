import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

/// A store under test, and the moment its domain clock reads.
///
/// [settle] waits until what was recorded is readable (a buffered store
/// writes it); each record settles alone, as if from another worker.
typedef StoreUnderTest = ({
  HorizonStore store,
  void Function(DateTime) setNow,
  Future<void> Function() settle,
});

/// The [HorizonStore] contract, the same for every store: run it once per
/// store with a [make] that gives a fresh, empty one.
void horizonStoreContract(
  String name,
  Future<StoreUnderTest> Function() make, {
  Future<void> Function()? tearDownStore,
}) {
  group('HorizonStore contract ($name)', () {
    late HorizonStore store;
    late void Function(DateTime) setNow;
    late Future<void> Function() settle;
    final start = DateTime.utc(2026, 11, 12, 9);

    void at(Duration later) => setNow(start.add(later));

    RecordedJob job(
      String uuid, {
      String status = 'completed',
      String queue = 'default',
      String name = 'SendInvoice',
      Duration later = Duration.zero,
      List<String> tags = const [],
      int? durationMs = 20,
    }) => RecordedJob(
      uuid: uuid,
      name: name,
      queue: queue,
      status: status,
      at: start.add(later).millisecondsSinceEpoch,
      tags: tags,
      durationMs: durationMs,
    );

    Future<void> rec(RecordedJob job) async {
      await store.record(job);
      await settle();
    }

    setUp(() async {
      final made = await make();
      store = made.store;
      setNow = made.setNow;
      settle = made.settle;
      at(Duration.zero);
    });
    if (tearDownStore != null) {
      tearDown(tearDownStore);
    }

    test('a recorded job is listed newest first, and found by uuid', () async {
      await rec(job('a'));
      await rec(job('b', later: const Duration(seconds: 1)));
      at(const Duration(seconds: 2));
      expect(
        [for (final j in await store.recent('completed')) j.uuid],
        ['b', 'a'],
      );
      expect(
        [for (final j in await store.recent('completed', offset: 1)) j.uuid],
        ['a'],
      );
      expect((await store.job('a'))?.name, 'SendInvoice');
      expect(await store.job('missing'), isNull);
      expect(await store.recent('failed'), isEmpty);
    });

    test('recording a job again replaces its record (idempotent per '
        'uuid)', () async {
      await rec(job('a', durationMs: 10));
      await rec(job('a', durationMs: 30));
      final listed = await store.recent('completed');
      expect(listed, hasLength(1));
      expect(listed.single.durationMs, 30);
    });

    test('a newer record moves the job to its new status', () async {
      await rec(job('a', status: 'failed'));
      await rec(
        job('a', status: 'completed', later: const Duration(seconds: 1)),
      );
      at(const Duration(seconds: 2));
      expect(await store.recent('failed'), isEmpty);
      expect((await store.job('a'))?.status, 'completed');
    });

    test('an older record arriving late never replaces a newer one', () async {
      await rec(
        job('a', status: 'completed', later: const Duration(seconds: 2)),
      );
      await rec(job('a', status: 'failed'));
      at(const Duration(seconds: 3));
      expect((await store.job('a'))?.status, 'completed');
      expect(await store.recent('failed'), isEmpty);
    });

    test('lists are replaced, counts are not: a job that failed, then '
        'completed, is listed once and its failure still counted', () async {
      await rec(job('a', status: 'failed', queue: 'mail'));
      await rec(job('a', queue: 'mail', later: const Duration(seconds: 1)));
      at(const Duration(seconds: 2));
      expect(await store.recent('failed'), isEmpty, reason: 'the list');
      expect([for (final j in await store.recent('completed')) j.uuid], ['a']);
      final summary = await store.summary();
      expect(summary['failed_past_week'], 1, reason: 'the failure happened');
      expect(summary['jobs_per_minute'], 2);
      expect((await store.rates('mail'))['per_second'], 2 / 60);
      await store.snapshot();
      final queues = (await store.metrics())['queues']! as Map<String, Object?>;
      expect(((queues['mail']! as List<Object?>).single! as Map)['count'], 2);
    });

    test('a record sent twice counts once', () async {
      await rec(job('a'));
      await rec(job('a'));
      at(const Duration(seconds: 1));
      expect((await store.summary())['jobs_per_minute'], 1);
    });

    test('rates and summary count the jobs of the last minute', () async {
      await rec(job('a', queue: 'mail', durationMs: 10));
      await rec(job('b', queue: 'mail', durationMs: 30));
      await rec(job('c', queue: 'other'));
      await rec(job('d', status: 'failed'));
      at(const Duration(seconds: 30));
      final rates = await store.rates('mail');
      expect(rates['per_second'], 2 / 60);
      expect(rates['avg_ms'], 20);
      final summary = await store.summary();
      expect(summary['jobs_per_minute'], 4);
      expect(summary['failed_past_week'], 1);
      at(const Duration(minutes: 2));
      expect((await store.rates('mail'))['per_second'], 0);
      expect((await store.rates('mail'))['avg_ms'], isNull);
    });

    test('monitored tags keep their jobs; unmonitor forgets them', () async {
      await store.monitor('user:7');
      await rec(job('a', tags: ['user:7']));
      await rec(job('b', tags: ['other']));
      expect(await store.monitored(), [
        {'tag': 'user:7', 'count': 1},
      ]);
      expect([for (final j in await store.tagged('user:7')) j.uuid], ['a']);
      await store.unmonitor('user:7');
      expect(await store.monitored(), isEmpty);
      expect(await store.tagged('user:7'), isEmpty);
    });

    test('a snapshot counts the jobs per name and per queue', () async {
      await rec(job('a', queue: 'mail', durationMs: 10));
      await rec(job('b', queue: 'mail', durationMs: 30));
      at(const Duration(seconds: 5));
      await store.snapshot();
      final metrics = await store.metrics();
      final jobs = metrics['jobs']! as Map<String, Object?>;
      final queues = metrics['queues']! as Map<String, Object?>;
      final mail = (queues['mail']! as List<Object?>).single! as Map;
      expect(mail['count'], 2);
      expect(mail['avg_ms'], 20);
      expect(jobs.keys, ['SendInvoice']);
    });
  });
}
