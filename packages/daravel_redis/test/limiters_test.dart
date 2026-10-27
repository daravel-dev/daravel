@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

/// `Redis.throttle` and `Redis.funnel` (Laravel's duration and concurrency
/// limiters), against `DARAVEL_TEST_REDIS`.
void main() {
  final url = Platform.environment['DARAVEL_TEST_REDIS'];
  if (url == null || url.isEmpty) {
    test('limiters (skipped: DARAVEL_TEST_REDIS not set)', () {}, skip: true);
    return;
  }
  late String prefix;
  late RedisClient client;
  setUp(() {
    prefix = 'test_${Random().nextInt(1 << 32)}_';
    client = RedisClient(RedisConnectionConfig.fromUrl(url));
  });
  tearDown(() async {
    final keys = await client.scan(match: '$prefix*').toList();
    if (keys.isNotEmpty) {
      await client.del(keys);
    }
    await client.close();
  });

  group('throttle', () {
    test('n per period, then the failure callback', () async {
      final runs = [
        for (var i = 0; i < 3; i++)
          await RedisThrottleBuilder(client, '${prefix}api')
              .allow(2)
              .every(const Duration(minutes: 1))
              .block(Duration.zero)
              .then(() => 'ran', (error) => 'refused'),
      ];
      expect(runs, ['ran', 'ran', 'refused']);
      // Laravel's hash: start, end and count.
      final hash = (await client.command(['HGETALL', '${prefix}api']))! as List;
      expect(hash, containsAllInOrder(['start', isA<String>(), 'end']));
      expect(hash.last, '3');

      final limiter = RedisDurationLimiter(
        client,
        '${prefix}api',
        maxLocks: 2,
        decay: const Duration(minutes: 1),
      );
      expect(await limiter.tooManyAttempts(), isTrue);
      await limiter.clear();
      expect(await limiter.acquire(), isTrue);
      expect(limiter.remaining, 1);
    });

    // Laravel's window runs from a whole second to that second plus the
    // decay: with 2 seconds, the next one opens 1 to 2 seconds later.
    test('block waits for the next period', () async {
      Future<String> run() => RedisThrottleBuilder(client, '${prefix}slow')
          .allow(1)
          .every(const Duration(seconds: 2))
          .block(const Duration(seconds: 5))
          .sleep(const Duration(milliseconds: 100))
          .then(() => 'ran');
      final watch = Stopwatch()..start();
      expect(await run(), 'ran');
      expect(await run(), 'ran');
      expect(watch.elapsed, greaterThan(const Duration(milliseconds: 900)));
    });

    test('without a failure callback, the timeout throws', () async {
      RedisThrottleBuilder throttle() => RedisThrottleBuilder(
        client,
        '${prefix}once',
      ).allow(1).every(const Duration(minutes: 1)).block(Duration.zero);
      expect(await throttle().then(() => 1), 1);
      await expectLater(
        throttle().then(() => 2),
        throwsA(isA<LimiterTimeoutException>()),
      );
    });
  });

  group('funnel', () {
    test('at most n at a time; the rest wait or fail', () async {
      var running = 0;
      var most = 0;
      Future<String> work(Duration block) =>
          RedisFunnelBuilder(client, '${prefix}imports')
              .limit(2)
              .block(block)
              .sleep(const Duration(milliseconds: 50))
              .then(() async {
                most = max(most, ++running);
                await Future<void>.delayed(const Duration(milliseconds: 300));
                running--;
                return 'ran';
              }, (error) => 'refused');

      expect(
        await Future.wait([for (var i = 0; i < 3; i++) work(Duration.zero)]),
        unorderedEquals(['ran', 'ran', 'refused']),
      );
      expect(
        await Future.wait([
          for (var i = 0; i < 4; i++) work(const Duration(seconds: 3)),
        ]),
        ['ran', 'ran', 'ran', 'ran'],
      );
      expect(most, 2);
    });

    test('a slot is freed when the work throws', () async {
      final funnel = RedisFunnelBuilder(
        client,
        '${prefix}one',
      ).limit(1).block(Duration.zero);
      await expectLater(
        funnel.then<void>(() => throw StateError('boom')),
        throwsStateError,
      );
      expect(await funnel.then(() => 'free again'), 'free again');
      expect(await client.command(['EXISTS', '${prefix}one1']), 0);
    });
  });
}
