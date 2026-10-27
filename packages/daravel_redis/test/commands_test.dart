import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_redis/commands.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:test/test.dart';

void main() {
  group('redis:cli', () {
    test('splits a line as redis-cli does', () {
      expect(parseRedisCommandLine('GET  user:7 '), ['GET', 'user:7']);
      expect(parseRedisCommandLine(r'SET k "a b\n" c'), [
        'SET',
        'k',
        'a b\n',
        'c',
      ]);
      expect(parseRedisCommandLine("SET k 'it''s'"), ['SET', 'k', 'its']);
      expect(parseRedisCommandLine('SET k ""'), ['SET', 'k', '']);
      expect(() => parseRedisCommandLine('GET "open'), throwsFormatException);
    });

    test('runs only reading commands without --write', () {
      expect(isReadOnlyRedisCommand(['get', 'k']), isTrue);
      expect(isReadOnlyRedisCommand(['CLUSTER', 'slots']), isTrue);
      expect(isReadOnlyRedisCommand(['CONFIG', 'GET', 'maxmemory']), isTrue);
      for (final args in [
        ['SET', 'k', 'v'],
        ['KEYS', '*'],
        ['FLUSHDB'],
        ['CONFIG', 'SET', 'maxmemory', '1'],
        ['CLUSTER', 'RESET'],
        ['EVAL', 'return 1', '0'],
        <String>[],
      ]) {
        expect(isReadOnlyRedisCommand(args), isFalse, reason: '$args');
      }
    });

    test('prints replies as redis-cli does', () {
      expect(formatRedisReply(null), '(nil)');
      expect(formatRedisReply(3), '(integer) 3');
      expect(formatRedisReply('a "b"'), r'"a \"b\""');
      expect(formatRedisReply(<Object?>[]), '(empty array)');
      expect(
        formatRedisReply(['a', 2, null]),
        '1) "a"\n2) (integer) 2\n3) (nil)',
      );
      expect(
        formatRedisReply([
          'x',
          ['y', 'z'],
        ]),
        '1) "x"\n2) 1) "y"\n   2) "z"',
      );
      expect(
        formatRedisReply(const RedisCommandException('ERR nope')),
        '(error) ERR nope',
      );
    });

    test('reads INFO', () {
      expect(
        parseRedisInfo(
          '# Server\r\nredis_version:7.4.1\r\nredis_mode:standalone\r\n',
        ),
        {'redis_version': '7.4.1', 'redis_mode': 'standalone'},
      );
    });
  });

  final url = Platform.environment['DARAVEL_TEST_REDIS'];
  if (url == null || url.isEmpty) {
    test('redis:* (skipped: DARAVEL_TEST_REDIS not set)', () {}, skip: true);
    return;
  }

  group('redis:* against a server', tags: ['integration'], () {
    final server = RedisConnectionConfig.fromUrl(url);
    late String prefix;
    late RedisClient client;
    setUp(() {
      prefix = 'test_${Random().nextInt(1 << 32)}_';
      client = RedisClient(server);
    });
    tearDown(() async {
      final keys = await client.scan(match: '$prefix*').toList();
      if (keys.isNotEmpty) {
        await client.del(keys);
      }
      await client.close();
    });

    Future<int?> dartisan(List<String> args) => DartisanRunner(
      () =>
          Application.configure(
            basePath: Directory.systemTemp.createTempSync('redis_cli_').path,
          ).withRedis().withEnv({
            'APP_ENV': 'testing',
            'LOG_LEVEL': 'error',
            'DB_DATABASE': ':memory:',
            'REDIS_URL': url,
            'REDIS_CACHE_DB': '${server.database}',
            'REDIS_PREFIX': prefix,
            'CACHE_PREFIX': 'c_',
          }).create(),
      commands: redisCommands,
    ).run(args);

    test('ping, stats, keys-audit and cli', () async {
      await client.set('${prefix}c_forever', '1');
      await client.set(
        '${prefix}c_short',
        '1',
        ttl: const Duration(minutes: 1),
      );
      await client.command(['HSET', '${prefix}h', 'f', 'v']);

      expect(await dartisan(['redis:ping']), 0);
      expect(await dartisan(['redis:stats']), 0);
      expect(await dartisan(['redis:keys-audit']), 0);
      expect(await dartisan(['redis:cli', 'GET', '${prefix}c_forever']), 0);
      // Writes need --write.
      expect(await dartisan(['redis:cli', 'SET', '${prefix}w', '1']), 1);
      expect(await client.get('${prefix}w'), isNull);
      expect(
        await dartisan(['redis:cli', '--write', 'SET', '${prefix}w', '1']),
        0,
      );
      expect(await client.get('${prefix}w'), '1');

      final audit = await auditRedisKeys(
        client,
        match: '$prefix*',
        cachePrefix: '${prefix}c_',
      );
      expect(audit.keys, 4);
      expect(audit.types, {'string': 3, 'hash': 1});
      expect(audit.withoutTtl, 3);
      expect(audit.cacheWithoutTtl, ['${prefix}c_forever']);
    });
  });
}
