import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

final class Exclusive extends Job {
  const Exclusive();
  @override
  String get jobName => 'exclusive';
  @override
  Map<String, Object?> toJson() => const {};
  @override
  Future<void> handle(JobContext ctx) async {}
}

/// The lock must be where QUEUE_UNIQUE_LOCK_STORE says: a `process` lock is
/// invisible to a `queue:work` in another process, and two run at once.
JobContext context() => JobContext(
  id: '1',
  attempt: 1,
  queue: 'default',
  connection: 'memory',
  payload: const {},
);

void main() {
  late Directory base;
  late Application app;

  setUp(() async {
    base = Directory.systemTemp.createTempSync('daravel_overlap');
    app = Application.configure(basePath: base.path)
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'QUEUE_UNIQUE_LOCK_STORE': 'locks',
        })
        .withCacheStore('locks', (_) => MemoryStore())
        .create();
    await app.boot();
  });

  tearDown(() async {
    await app.shutdown();
    base.deleteSync(recursive: true);
  });

  test('WithoutOverlapping locks in the configured store', () async {
    await app.run(() async {
      final held = App.make<CacheManager>()
          .store('locks')
          .lock('overlap:exclusive:a', ttl: const Duration(minutes: 1));
      expect(await held.acquire(), isTrue);
      var ran = false;
      final ctx = context();
      await const WithoutOverlapping('a')
          .handle(ctx, const Exclusive(), () async {
            ran = true;
          });
      expect(ran, isFalse, reason: 'the lock in the file store is held');
      await held.release();
    });
  });

  test('shared: another job with the key waits too', () async {
    await app.run(() async {
      final held = App.make<CacheManager>()
          .store('locks')
          .lock('overlap:report', ttl: const Duration(minutes: 1));
      expect(await held.acquire(), isTrue);
      var ran = false;
      await const WithoutOverlapping('report', shared: true).handle(
        context(),
        const Exclusive(),
        () async {
          ran = true;
        },
      );
      expect(ran, isFalse);
      await held.release();
    });
  });

  test('an explicit store still wins', () async {
    await app.run(() async {
      var ran = false;
      final held = App.make<CacheManager>()
          .store('locks')
          .lock('overlap:exclusive:b', ttl: const Duration(minutes: 1));
      expect(await held.acquire(), isTrue);
      await const WithoutOverlapping('b', store: 'process').handle(
        context(),
        const Exclusive(),
        () async {
          ran = true;
        },
      );
      expect(ran, isTrue);
      await held.release();
    });
  });
}
