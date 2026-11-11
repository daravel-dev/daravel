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
