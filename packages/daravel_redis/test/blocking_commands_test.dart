import 'dart:io';
import 'dart:math';

import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

/// Blocking commands wait as long as they block, on a connection of their
/// own, not the 1 s command timeout of the shared connection
/// (daravel-feedback 034: `XREADGROUP … BLOCK 2000` timed out after 1000ms
/// and closed the connection).
void main() {
  group('RedisClient.blockingTimeout', () {
    test('reads the timeout of each blocking command', () {
      expect(
        RedisClient.blockingTimeout(['BLPOP', 'a', 'b', '5']),
        const Duration(seconds: 5),
      );
      expect(
        RedisClient.blockingTimeout(['brpop', 'a', '0.25']),
        const Duration(milliseconds: 250),
      );
      expect(
        RedisClient.blockingTimeout(['BLMOVE', 'a', 'b', 'LEFT', 'RIGHT', 2]),
        const Duration(seconds: 2),
      );
      expect(
        RedisClient.blockingTimeout(['BZPOPMIN', 'z', 1]),
        const Duration(seconds: 1),
      );
      expect(
        RedisClient.blockingTimeout(['BLMPOP', '3', '1', 'a', 'LEFT']),
        const Duration(seconds: 3),
      );
      expect(
        RedisClient.blockingTimeout(['WAIT', 1, 100]),
        const Duration(milliseconds: 100),
      );
      expect(
        RedisClient.blockingTimeout(['WAITAOF', 1, 0, 50]),
        const Duration(milliseconds: 50),
      );
      expect(
        RedisClient.blockingTimeout([
          'XREADGROUP', 'GROUP', 'g', 'c', 'COUNT', 10, //
          'BLOCK', 2000, 'STREAMS', 's', '>',
        ]),
        const Duration(seconds: 2),
      );
    });

    test('zero means without limit', () {
      expect(RedisClient.blockingTimeout(['BLPOP', 'a', '0']), Duration.zero);
      expect(
        RedisClient.blockingTimeout(['XREAD', 'BLOCK', '0', 'STREAMS', 's', 0]),
        Duration.zero,
      );
    });

    test('null for commands that do not block', () {
      expect(RedisClient.blockingTimeout(['GET', 'a']), isNull);
      expect(RedisClient.blockingTimeout(['LPOP', 'a']), isNull);
      expect(
        RedisClient.blockingTimeout(['XREAD', 'COUNT', 1, 'STREAMS', 's', 0]),
        isNull,
      );
      // A stream named BLOCK is not the option.
      expect(
        RedisClient.blockingTimeout(['XREAD', 'STREAMS', 'BLOCK', '0']),
        isNull,
      );
    });
  });

  final url = Platform.environment['DARAVEL_TEST_REDIS'];
  if (url == null || url.isEmpty) {
    test(
      'blocking commands (skipped: DARAVEL_TEST_REDIS not set)',
      () {},
      skip: true,
    );
    return;
  }

  group('against Redis', tags: ['integration'], () {
    late String prefix;
    late RedisClient client;
    setUp(() {
      prefix = 'test_${Random().nextInt(1 << 32)}_';
      client = RedisClient(
        RedisConnectionConfig.fromUrl(url)
            .copyWith(commandTimeout: const Duration(milliseconds: 300)),
      );
    });
    tearDown(() async {
      final keys = await client.scan(match: '$prefix*').toList();
      if (keys.isNotEmpty) {
        await client.del(keys);
      }
      await client.close();
    });

    test('XREADGROUP BLOCK longer than the command timeout', () async {
      final stream = '${prefix}answers';
      await client.command(['XGROUP', 'CREATE', stream, 'g', r'$', 'MKSTREAM']);
      final watch = Stopwatch()..start();
      final reply = await client.command([
        'XREADGROUP', 'GROUP', 'g', 'c', 'COUNT', 10, //
        'BLOCK', 800, 'STREAMS', stream, '>',
      ]);
      expect(reply, isNull);
      expect(watch.elapsed, greaterThanOrEqualTo(Duration(milliseconds: 700)));
    });

    test(
      'BLPOP wakes on a push, and the shared connection stays free',
      () async {
        final list = '${prefix}jobs';
        final popped = client.command(['BLPOP', list, '2']);
        // Commands on the shared connection are not queued behind the BLPOP.
        expect(await client.command(['PING']), 'PONG');
        await client.command(['RPUSH', list, 'job-1']);
        expect(await popped, [list, 'job-1']);
      },
    );

    test('a BLPOP that times out on the server returns null', () async {
      expect(await client.command(['BLPOP', '${prefix}empty', '0.5']), isNull);
      // The connection is reused for the next blocking command.
      expect(await client.command(['BLPOP', '${prefix}empty', '0.5']), isNull);
      expect(client.stats['dedicated'], 1);
    });
  });
}
