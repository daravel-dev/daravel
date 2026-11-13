import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

final class _Ping extends Job {
  const _Ping();

  @override
  String get jobName => 'ping';

  @override
  Map<String, Object?> toJson() => const {};

  @override
  Future<void> handle(JobContext ctx) async {}
}

/// A payload the Redis queue cannot decode is removed from Redis by `pop`
/// and recorded in `failed_jobs` by the worker, whatever it is: not JSON
/// (`{{{corrupt`), empty, or JSON that is not a job. Before, one that was
/// not JSON made the failed job provider throw after the removal: the job
/// was gone with no row. Runs against a real Redis or Valkey when
/// `DARAVEL_TEST_REDIS` is set; `failed_jobs` is in SQLite.
void main() {
  final url = Platform.environment['DARAVEL_TEST_REDIS'];
  if (url == null || url.isEmpty) {
    test('Redis (skipped: DARAVEL_TEST_REDIS not set)', () {}, skip: true);
    return;
  }
  const corrupt = ['{{{corrupt', '', '[1,2,3]', '123', '{"job":"ping"}'];

  for (final engine in RedisQueueEngine.values) {
    test('${engine.name}: every payload that does not decode is in '
        'failed_jobs, and gone from Redis', () async {
      final dir = await Directory.systemTemp.createTemp('redis_corrupt_');
      final prefix = 'test_${Random().nextInt(1 << 32)}_';
      final app = Application.configure(basePath: dir.path)
          .withRedis()
          .withEnv({
            'APP_ENV': 'testing',
            'DB_CONNECTION': 'sqlite',
            'DB_DATABASE': '${dir.path}${Platform.pathSeparator}db.sqlite',
            'QUEUE_CONNECTION': 'redis',
            'QUEUE_REDIS_ENGINE': engine.name,
            'REDIS_URL': url,
            'REDIS_PREFIX': prefix,
          })
          .withLogLevel(LogLevel.critical)
          .withMigrations(const [CreateJobsTable()])
          .withJobs([JobDefinition('ping', (_) => const _Ping())])
          .create();
      await app.boot();
      final client = RedisClient(RedisConnectionConfig.fromUrl(url));
      addTearDown(() async {
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
        await app.shutdown();
        try {
          await dir.delete(recursive: true);
        } on FileSystemException {
          // Windows may still hold the file.
        }
      });
      await app.run(() async {
        await App.make<Migrator>().run();
        final kind = engine == RedisQueueEngine.stream ? 'stream' : 'queue';
        final worker = QueueWorker(Queue.manager);
        for (final raw in corrupt) {
          final job = JobPayload.forJob(const _Ping());
          await Queue.connection().push(job, queue: 'default');
          // The stored payload, replaced by one that does not decode.
          await client.command([
            'HSET',
            '${prefix}daravel:$kind:{default}:job:${job.uuid}',
            'payload',
            raw,
          ]);
          expect(
            await worker.runNextJob(Queue.connection(), const WorkerOptions()),
            isTrue,
            reason: raw,
          );
        }
        expect(await Queue.connection().size('default'), 0);
        final failed = await DB.table('failed_jobs').orderBy('id').get();
        expect([for (final row in failed) row['payload']], corrupt);
        for (final row in failed) {
          expect(row['connection'], 'redis');
          expect(row['uuid'], isA<String>());
        }
      });
    });
  }
}
