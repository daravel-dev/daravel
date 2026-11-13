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

/// Deleting a job that waits (one `daravel_horizon` quarantines after a
/// reclaim, a delayed one) removes its id from the list, the stream or the
/// delayed set too, not only its hash, so `size` no longer counts it.
/// With `DARAVEL_TEST_REDIS`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_REDIS'];
  if (url == null || url.isEmpty) {
    test(
      'deleting waiting jobs (skipped: DARAVEL_TEST_REDIS not set)',
      () {},
      skip: true,
    );
    return;
  }

  for (final engine in RedisQueueEngine.values) {
    group(engine.name, () {
      late String prefix;
      late RedisClient client;
      late RedisQueue queue;

      setUp(() {
        prefix = 'test_${Random().nextInt(1 << 32)}_';
        client = RedisClient(RedisConnectionConfig.fromUrl(url));
        queue = RedisQueue(
          client,
          prefix: prefix,
          retryAfter: const Duration(seconds: 30),
          engine: engine,
        );
      });

      tearDown(() async {
        await queue.clear('default');
        await queue.stopWaiting();
        await client.close();
      });

      /// The waiting job as `pending` shows it, as a job to delete.
      Future<QueuedJob> waiting() async {
        final view = (await queue.pending('default')).single;
        return QueuedJob(
          id: view.id,
          queue: 'default',
          payload: JobPayload.decode(view.payload),
          attempts: view.attempts,
          raw: view.payload,
        );
      }

      test('a job never reserved', () async {
        await queue.push(JobPayload.forJob(const _Job()), queue: 'default');
        expect(await queue.size('default'), 1);
        await queue.delete(await waiting());
        expect(await queue.size('default'), 0);
        expect(await queue.pop('default'), isNull);
      });

      test('a delayed job', () async {
        final payload = JobPayload.forJob(const _Job());
        final id = await queue.push(
          payload,
          queue: 'default',
          delay: const Duration(minutes: 5),
        );
        expect(await queue.size('default'), 1);
        await queue.delete(
          QueuedJob(
            id: id,
            queue: 'default',
            payload: payload,
            attempts: 0,
            raw: payload.encode(),
          ),
        );
        expect(await queue.size('default'), 0);
      });

      test('a job taken back by reclaim (Horizon quarantines it)', () async {
        await queue.push(JobPayload.forJob(const _Job()), queue: 'default');
        final reserved = (await queue.pop('default'))!;
        expect(await queue.reclaim('default', reserved.id), isTrue);
        final job = await waiting();
        expect(job.attempts, 1);
        await queue.delete(job);
        expect(await queue.size('default'), 0);
        expect(await queue.pop('default'), isNull);
      });

      test('a released job, and a reserved one, as before', () async {
        await queue.push(JobPayload.forJob(const _Job()), queue: 'default');
        final reserved = (await queue.pop('default'))!;
        await queue.release(reserved, Duration.zero);
        await queue.delete(await waiting());
        expect(await queue.size('default'), 0);

        await queue.push(JobPayload.forJob(const _Job()), queue: 'default');
        final again = (await queue.pop('default'))!;
        await queue.delete(again);
        expect(await queue.size('default'), 0);
      });
    });
  }
}
