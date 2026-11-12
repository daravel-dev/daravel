@Tags(['conformance'])
library;

import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/conformance.dart';
import 'package:test/test.dart';

/// A job named as its Laravel class, so both applications build the same
/// keys (ADR-041).
final class SendInvoice extends Job {
  const SendInvoice(this.invoice);

  final String invoice;

  @override
  String get jobName => 'send-invoice';

  @override
  String get displayName => r'App\Jobs\SendInvoice';

  @override
  String? get uniqueId => invoice;

  @override
  Map<String, Object?> toJson() => {'invoice': invoice};

  @override
  Future<void> handle(JobContext ctx) async {}
}

/// A job whose Laravel class defines `displayName()`: Laravel names its
/// unique lock by the XXH3-128 of that name.
final class SendInvoiceNamed extends Job {
  const SendInvoiceNamed(this.invoice);

  final String invoice;

  @override
  String get jobName => 'send-invoice-named';

  @override
  String get displayName => 'Send invoice to customer #42';

  @override
  bool get uniqueKeyHashesDisplayName => true;

  @override
  String? get uniqueId => invoice;

  @override
  Map<String, Object?> toJson() => {'invoice': invoice};

  @override
  Future<void> handle(JobContext ctx) async {}
}

/// ADR-041: the unique, overlap and debounce keys are Laravel's, and during
/// the transition the previous release's keys are taken too, so an
/// instance of either release refuses the other's dispatch.
void main() {
  group("Laravel's key formats", () {
    test('unique: laravel_unique_job:<class>:<id> (UniqueLock::getKey)', () {
      expect(
        QueueLockKeys.unique(r'App\Jobs\SendInvoice', '42'),
        LaravelContract.uniqueJobLock(r'App\Jobs\SendInvoice', '42'),
      );
    });

    test('overlap: laravel-queue-overlap:[<class>:]<key> '
        '(WithoutOverlapping::getLockKey)', () {
      expect(
        QueueLockKeys.overlap(r'App\Jobs\SendInvoice', 'k'),
        LaravelContract.overlapLock(r'App\Jobs\SendInvoice', 'k'),
      );
      expect(
        QueueLockKeys.overlap(r'App\Jobs\SendInvoice', 'k', shared: true),
        LaravelContract.overlapLock(r'App\Jobs\SendInvoice', 'k', shared: true),
      );
    });

    test('debounce: laravel_debounced_job:<class>:<id> (13.x '
        'DebounceLock::getKey)', () {
      expect(
        QueueLockKeys.debounce(r'App\Jobs\SendInvoice', 'd'),
        LaravelContract.debouncedJobKey(r'App\Jobs\SendInvoice', 'd'),
      );
      expect(
        '${QueueLockKeys.debounce(r'App\Jobs\SendInvoice', 'd')}'
        ':first_dispatched_at',
        LaravelContract.debouncedJobFirstDispatch(r'App\Jobs\SendInvoice', 'd'),
      );
    });

    test("unique, a job class with displayName(): hash('xxh128', "
        r"$job->displayName()) (UniqueLock::getKey), the value PHP gives", () {
      expect(
        QueueLockKeys.unique(
          'Send invoice to customer #42',
          '42',
          hashed: true,
        ),
        LaravelContract.uniqueJobLockHashedSample,
      );
    });

    test('a worker releases the hashed key and the previous release\'s', () {
      expect(
        QueueLockKeys.uniqueKeysOf(
          'laravel_unique_job:fea1a00a16e1af75dea119255a9a933a:42',
          displayName: 'Send invoice to customer #42',
          jobName: 'send-invoice-named',
        ),
        [
          'laravel_unique_job:fea1a00a16e1af75dea119255a9a933a:42',
          'unique:send-invoice-named:42',
        ],
      );
    });

    test('a worker releases both formats, whichever release dispatched '
        'the job', () {
      expect(
        QueueLockKeys.uniqueKeysOf(
          r'laravel_unique_job:App\Jobs\SendInvoice:42',
          displayName: r'App\Jobs\SendInvoice',
          jobName: 'send-invoice',
        ),
        [
          r'laravel_unique_job:App\Jobs\SendInvoice:42',
          'unique:send-invoice:42',
        ],
      );
      expect(
        QueueLockKeys.uniqueKeysOf(
          'unique:send-invoice:42',
          displayName: r'App\Jobs\SendInvoice',
          jobName: 'send-invoice',
        ),
        [
          r'laravel_unique_job:App\Jobs\SendInvoice:42',
          // The previous release could not know which form this one takes.
          'laravel_unique_job:${Xxh128.hex(r'App\Jobs\SendInvoice')}:42',
          'unique:send-invoice:42',
        ],
      );
    });
  });

  group('transition: both keys taken (ADR-041)', () {
    late Application app;

    setUp(() async {
      app =
          Application.configure(
                basePath: Directory.systemTemp
                    .createTempSync('daravel_lock_keys_')
                    .path,
              )
              .withEnv(const {
                'APP_ENV': 'testing',
                'DB_DATABASE': ':memory:',
                'QUEUE_CONNECTION': 'memory',
              })
              .withJobs([
                JobDefinition(
                  'send-invoice',
                  (j) => SendInvoice(j['invoice']! as String),
                ),
                JobDefinition(
                  'send-invoice-named',
                  (j) => SendInvoiceNamed(j['invoice']! as String),
                ),
              ])
              .create();
      await app.boot();
    });
    tearDown(() => app.shutdown());

    CacheRepository locks() => app.container.make<CacheManager>().store(
      app.container
          .make<ConfigRepository>()
          .section<QueueConfig>()
          .uniqueLockStore,
    );
    Future<int> size() =>
        app.container.make<QueueManager>().connection('memory').size('default');

    test('a job with uniqueKeyHashesDisplayName locks under the hashed key '
        "(Laravel's for its class), and a worker frees both keys", () async {
      await app.run(() async {
        final queues = app.container.make<QueueManager>();
        await queues.push(const SendInvoiceNamed('42'));
        expect(await size(), 1);
        final hashed = locks().lock(
          'laravel_unique_job:fea1a00a16e1af75dea119255a9a933a:42',
          ttl: const Duration(minutes: 1),
        );
        expect(await hashed.acquire(), isFalse, reason: 'held by the job');
        await queues.push(const SendInvoiceNamed('42'));
        expect(await size(), 1, reason: 'a second dispatch is refused');
        await QueueWorker(queues)
            .runNextJob(queues.connection('memory'), const WorkerOptions());
        expect(await hashed.acquire(), isTrue, reason: 'freed');
        final old = locks().lock(
          'unique:send-invoice-named:42',
          ttl: const Duration(minutes: 1),
        );
        expect(await old.acquire(), isTrue, reason: 'the old key freed too');
      });
    });

    test('an instance of the previous release holding the old key refuses '
        "this release's dispatch", () async {
      await app.run(() async {
        final old = locks().lock(
          'unique:send-invoice:42',
          ttl: const Duration(minutes: 1),
        );
        expect(await old.acquire(), isTrue);
        await app.container.make<QueueManager>().push(const SendInvoice('42'));
        expect(await size(), 0, reason: 'refused');
        // Not left holding Laravel's key either.
        final current = locks().lock(
          r'laravel_unique_job:App\Jobs\SendInvoice:42',
          ttl: const Duration(minutes: 1),
        );
        expect(await current.acquire(), isTrue);
      });
    });

    test('a job this release dispatched and a worker of the previous '
        'release finished: the old key it leaves behind lapses after '
        'legacyWindow, not after uniqueFor', () async {
      Clock.freeze();
      addTearDown(Clock.restore);
      await app.run(() async {
        await app.container.make<QueueManager>().push(const SendInvoice('44'));
        // The previous release's worker releases only payload.uniqueKey
        // (Laravel's key): it does not know uniqueKeysOf.
        await locks()
            .lock(LaravelContract.uniqueJobLock(r'App\Jobs\SendInvoice', '44'))
            .forceRelease();
        // Within the window the old key still refuses the id.
        Clock.travel(QueueLockKeys.legacyWindow - const Duration(minutes: 1));
        await app.container.make<QueueManager>().push(const SendInvoice('44'));
        expect(await size(), 1, reason: 'refused within the window');
        // Past it the id is accepted again (SendInvoice has uniqueFor 0:
        // 365 days before this bound).
        Clock.travel(const Duration(minutes: 2));
        await app.container.make<QueueManager>().push(const SendInvoice('44'));
        expect(await size(), 2, reason: 'accepted after the window');
      });
    });

    test('the debounce owner under the old key lapses after legacyWindow '
        "too; Laravel's key keeps its own TTL", () async {
      expect(
        QueueLockKeys.legacyTtl(const Duration(days: 365)),
        QueueLockKeys.legacyWindow,
      );
      expect(
        QueueLockKeys.legacyTtl(const Duration(minutes: 5)),
        const Duration(minutes: 5),
      );
    });

    test("this release's dispatch holds the old key, so the previous "
        'release (and Laravel, on the new key) refuse theirs', () async {
      await app.run(() async {
        await app.container.make<QueueManager>().push(const SendInvoice('43'));
        expect(await size(), 1);
        final old = locks().lock(
          'unique:send-invoice:43',
          ttl: const Duration(minutes: 1),
        );
        expect(await old.acquire(), isFalse);
        final laravel = locks().lock(
          LaravelContract.uniqueJobLock(r'App\Jobs\SendInvoice', '43'),
          ttl: const Duration(minutes: 1),
        );
        expect(await laravel.acquire(), isFalse);
      });
    });
  });
}
