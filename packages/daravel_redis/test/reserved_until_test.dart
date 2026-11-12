import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

final class Ping extends Job {
  const Ping();

  @override
  String get jobName => 'ping';

  @override
  Map<String, Object?> toJson() => const {};

  @override
  Future<void> handle(JobContext context) async {}
}

/// `QueuedJob.reservedUntil` of the Redis queue: the pop's time plus
/// `retry_after` to the millisecond. The list engine keeps the job until
/// then on the popping process's clock (exactly, below); the stream engine
/// counts the reservation on the Redis server's clock (XAUTOCLAIM), so
/// only the value is checked there.
void main() {
  final url = Platform.environment['DARAVEL_TEST_REDIS'];
  if (url == null || url.isEmpty) {
    test(
      'reservedUntil (skipped: DARAVEL_TEST_REDIS not set)',
      () {},
      skip: true,
    );
    return;
  }
  final server = RedisConnectionConfig.fromUrl(url);
  late RedisClient client;
  late String prefix;

  setUp(() {
    client = RedisClient(server);
    prefix = 'test_${Random().nextInt(1 << 32)}_';
  });
  tearDown(() async {
    Clock.restore();
    final keys = (await client.command(['KEYS', '$prefix*']))! as List;
    if (keys.isNotEmpty) {
      await client.command(['DEL', ...keys]);
    }
    await client.close();
  });

  // A second boundary, as epoch milliseconds.
  const second = 1800000000 * 1000;
  const retryAfter = Duration(milliseconds: 3000);

  for (final fraction in [0, 500, 999]) {
    test('list engine, popped at .$fraction s: reserved until exactly '
        'the pop plus retry_after', () async {
      final queue = RedisQueue(
        client,
        prefix: prefix,
        retryAfter: retryAfter,
        engine: RedisQueueEngine.list,
      );
      addTearDown(queue.stopWaiting);
      Clock.travelTo(
        DateTime.fromMillisecondsSinceEpoch(second + fraction, isUtc: true),
      );
      await queue.push(JobPayload.forJob(const Ping()), queue: 'default');
      final first = (await queue.pop('default'))!;
      final expected = second + fraction + retryAfter.inMilliseconds;
      expect(first.reservedUntil!.millisecondsSinceEpoch, expected);

      Clock.travelTo(
        DateTime.fromMillisecondsSinceEpoch(expected - 1, isUtc: true),
      );
      expect(await queue.pop('default'), isNull, reason: '1 ms before');

      Clock.travelTo(
        DateTime.fromMillisecondsSinceEpoch(expected, isUtc: true),
      );
      final again = (await queue.pop('default'))!;
      expect(again.id, first.id);
      expect(again.attempts, 2);
    });
  }

  test('stream engine: the pop plus retry_after', () async {
    final queue = RedisQueue(
      client,
      prefix: prefix,
      retryAfter: retryAfter,
      engine: RedisQueueEngine.stream,
    );
    addTearDown(queue.stopWaiting);
    Clock.travelTo(
      DateTime.fromMillisecondsSinceEpoch(second + 500, isUtc: true),
    );
    await queue.push(JobPayload.forJob(const Ping()), queue: 'default');
    final job = (await queue.pop('default'))!;
    expect(
      job.reservedUntil!.millisecondsSinceEpoch,
      second + 500 + retryAfter.inMilliseconds,
    );
  });
}
