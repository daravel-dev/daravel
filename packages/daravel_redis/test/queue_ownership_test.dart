import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

final class _Job extends Job {
  const _Job();

  @override
  String get jobName => 'job';

  @override
  Map<String, Object?> toJson() => const {};

  @override
  Future<void> handle(JobContext ctx) async {}
}

/// A worker that ran past `retry_after` acts on a job another worker took
/// since: its `delete` and `release` change nothing (the job's `attempts`,
/// raised by every reservation, are no longer its own), and it is told
/// once. A hash left without its payload is a corrupt job, removed. With
/// `DARAVEL_TEST_REDIS`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_REDIS'];
  if (url == null || url.isEmpty) {
    test(
      'queue ownership (skipped: DARAVEL_TEST_REDIS not set)',
      () {},
      skip: true,
    );
    return;
  }

  for (final engine in RedisQueueEngine.values) {
    group(engine.name, () {
      late String prefix;
      late RedisClient client;
      late MemoryHandler logs;
      late RedisQueue queue;
      const retryAfter = Duration(milliseconds: 300);

      setUp(() {
        prefix = 'test_${Random().nextInt(1 << 32)}_';
        client = RedisClient(RedisConnectionConfig.fromUrl(url));
        logs = MemoryHandler();
        queue = RedisQueue(
          client,
          prefix: prefix,
          retryAfter: retryAfter,
          engine: engine,
          logger: Logger(handlers: [logs]),
        );
      });

      tearDown(() async {
        await queue.stopWaiting();
        var cursor = '0';
        do {
          final reply =
              (await client.command(['SCAN', cursor, 'MATCH', '$prefix*']))!
                  as List;
          cursor = reply[0]! as String;
          final keys = (reply[1]! as List).cast<String>();
          if (keys.isNotEmpty) {
            await client.command(['DEL', ...keys]);
          }
        } while (cursor != '0');
        await client.close();
      });

      final kind = engine == RedisQueueEngine.stream ? 'stream' : 'queue';
      String hashOf(QueuedJob job) =>
          '${prefix}daravel:$kind:{default}:job:${job.id}';
      Future<bool> hashExists(QueuedJob job) async =>
          await client.command(['EXISTS', hashOf(job)]) == 1;

      /// A pops; its reservation runs out; B pops the same job.
      Future<(QueuedJob, QueuedJob)> taken() async {
        await queue.push(JobPayload.forJob(const _Job()), queue: 'default');
        final a = (await queue.pop('default'))!;
        await Future<void>.delayed(
          retryAfter + const Duration(milliseconds: 150),
        );
        final b = (await queue.pop('default'))!;
        expect(b.id, a.id);
        expect(b.attempts, a.attempts + 1);
        return (a, b);
      }

      int warnings() =>
          logs.matching(LogLevel.warning, 'ran past retry_after').length;

      test('(1) the first worker deletes: the second keeps the job', () async {
        final (a, b) = await taken();
        await queue.delete(a);
        expect(await hashExists(b), isTrue, reason: "B's job is still there");
        expect(warnings(), 1);
        await queue.delete(b);
        expect(await hashExists(b), isFalse);
        expect(await queue.size('default'), 0);
      });

      test('(2) the first worker releases: the second keeps its '
          'reservation; no third worker runs it', () async {
        final (a, b) = await taken();
        await queue.release(a, Duration.zero);
        expect(await queue.pop('default'), isNull, reason: 'no C');
        await queue.delete(b);
        expect(await queue.size('default'), 0);
        expect(warnings(), 1);
      });

      test('(3) a release after the job was deleted makes no job', () async {
        final (a, b) = await taken();
        await queue.delete(b);
        await queue.release(a, Duration.zero);
        expect(await hashExists(a), isFalse, reason: 'no hash without payload');
        expect(await queue.size('default'), 0);
        expect(await queue.pop('default'), isNull);
      });

      test('(4) releasing twice queues one copy', () async {
        await queue.push(JobPayload.forJob(const _Job()), queue: 'default');
        final job = (await queue.pop('default'))!;
        await queue.release(job, Duration.zero);
        await queue.release(job, Duration.zero);
        final again = (await queue.pop('default'))!;
        expect(again.id, job.id);
        expect(await queue.pop('default'), isNull, reason: 'one copy only');
        await queue.delete(again);
        expect(await queue.size('default'), 0);
        expect(warnings(), 1, reason: 'the second release, told once');
      });

      test('(5) a job hash without its payload is corrupt, not a type '
          'error each retry_after', () async {
        await queue.push(JobPayload.forJob(const _Job()), queue: 'default');
        final job = (await queue.pop('default'))!;
        await client.command(['HDEL', hashOf(job), 'payload']);
        await Future<void>.delayed(
          retryAfter + const Duration(milliseconds: 150),
        );
        await expectLater(
          queue.pop('default'),
          throwsA(isA<CorruptPayloadException>()),
        );
        expect(await hashExists(job), isFalse);
        await Future<void>.delayed(
          retryAfter + const Duration(milliseconds: 150),
        );
        expect(await queue.pop('default'), isNull, reason: 'gone for good');
      });
    });
  }
}
