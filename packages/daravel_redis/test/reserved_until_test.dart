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

  for (final fraction in [0, 500, 999]) {
    test('list engine, extended at .$fraction s: kept until exactly the '
        'extension plus retry_after', () async {
      final queue = RedisQueue(
        client,
        prefix: prefix,
        retryAfter: retryAfter,
        engine: RedisQueueEngine.list,
      );
      addTearDown(queue.stopWaiting);
      Clock.travelTo(DateTime.fromMillisecondsSinceEpoch(second, isUtc: true));
      await queue.push(JobPayload.forJob(const Ping()), queue: 'default');
      final job = (await queue.pop('default'))!;

      final at = second + 1000 + fraction;
      Clock.travelTo(DateTime.fromMillisecondsSinceEpoch(at, isUtc: true));
      final until = await queue.extend(job);
      final expected = at + retryAfter.inMilliseconds;
      expect(until!.millisecondsSinceEpoch, expected);

      Clock.travelTo(
        DateTime.fromMillisecondsSinceEpoch(expected - 1, isUtc: true),
      );
      expect(await queue.pop('default'), isNull, reason: '1 ms before');
      Clock.travelTo(
        DateTime.fromMillisecondsSinceEpoch(expected, isUtc: true),
      );
      expect((await queue.pop('default'))!.id, job.id);
    });
  }

  for (final engine in RedisQueueEngine.values) {
    test(
      '${engine.name} engine: extend after the job was deleted is null',
      () async {
        final queue = RedisQueue(
          client,
          prefix: prefix,
          retryAfter: retryAfter,
          engine: engine,
        );
        addTearDown(queue.stopWaiting);
        Clock.travelTo(
          DateTime.fromMillisecondsSinceEpoch(second, isUtc: true),
        );
        await queue.push(JobPayload.forJob(const Ping()), queue: 'default');
        final done = (await queue.pop('default'))!;
        // Later than the pop: in the same millisecond nothing would move.
        Clock.travelTo(
          DateTime.fromMillisecondsSinceEpoch(second + 100, isUtc: true),
        );
        expect(await queue.extend(done), isNotNull, reason: 'still mine');
        await queue.delete(done);
        expect(await queue.extend(done), isNull);
      },
    );
  }

  test('list engine: extend once the reservation ended is null, whether the '
      'job waits in the list again or another worker reserved it', () async {
    final queue = RedisQueue(
      client,
      prefix: prefix,
      retryAfter: retryAfter,
      engine: RedisQueueEngine.list,
    );
    addTearDown(queue.stopWaiting);
    Clock.travelTo(DateTime.fromMillisecondsSinceEpoch(second, isUtc: true));
    await queue.push(JobPayload.forJob(const Ping()), queue: 'default');
    final mine = (await queue.pop('default'))!;
    await queue.push(JobPayload.forJob(const Ping()), queue: 'default');

    // Past its end, a pop moves it back behind the other job and takes
    // that one: it waits in the list, its attempts unchanged.
    Clock.travelTo(
      DateTime.fromMillisecondsSinceEpoch(
        second + retryAfter.inMilliseconds,
        isUtc: true,
      ),
    );
    final other = (await queue.pop('default'))!;
    expect(other.id, isNot(mine.id));
    expect(await queue.extend(mine), isNull, reason: 'back in the list');

    final theirs = (await queue.pop('default'))!;
    expect(theirs.id, mine.id);
    expect(theirs.attempts, 2);
    expect(await queue.extend(mine), isNull, reason: 'reserved again');
  });
}
