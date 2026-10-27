@Tags(['integration'])
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:daravel/daravel.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

/// Tagged entries in Laravel 12's layout, on one server
/// (`DARAVEL_TEST_REDIS`) and a cluster (`DARAVEL_TEST_REDIS_CLUSTER`).
void main() {
  for (final (name, variable) in [
    ('server', 'DARAVEL_TEST_REDIS'),
    ('cluster', 'DARAVEL_TEST_REDIS_CLUSTER'),
  ]) {
    final url = Platform.environment[variable];
    if (url == null || url.isEmpty) {
      test('tags on a $name (skipped: $variable not set)', () {}, skip: true);
      continue;
    }
    group('tags on a $name', () {
      late String prefix;
      late RedisClient client;
      late CacheRepository cache;

      setUp(() {
        prefix = 'test_${Random().nextInt(1 << 32)}_';
        client = RedisClient(RedisConnectionConfig.fromUrl(url));
        cache = CacheRepository(
          RedisStore(client, prefix: prefix, flushPrefix: 'c_'),
          prefix: 'c_',
        );
      });
      tearDown(() async {
        Clock.restore();
        final keys = await client.scan(match: '$prefix*').toList();
        if (keys.isNotEmpty) {
          await client.del(keys);
        }
        await client.close();
      });

      String namespace(List<String> tags) => sha1
          .convert(utf8.encode(tags.map((t) => 'tag:$t:entries').join('|')))
          .toString();

      test("keys and tag lists are Laravel's", () async {
        Clock.freeze();
        final now = Clock.now().toUtc().millisecondsSinceEpoch ~/ 1000;
        final tagged = cache.tags(['people', 'artists']);
        await tagged.put('John', 'x', ttl: const Duration(minutes: 1));
        await tagged.forever('Anne', 'y');
        final ns = namespace(['people', 'artists']);
        expect(await client.get('${prefix}c_$ns:John'), '"x"');
        for (final tag in ['people', 'artists']) {
          final list = await client.command([
            'ZRANGE',
            '${prefix}c_tag:$tag:entries',
            0,
            -1,
            'WITHSCORES',
          ]);
          expect(list, ['$ns:Anne', '-1', '$ns:John', '${now + 60}']);
        }
        expect(await tagged.get<String>('John'), 'x');
        expect(
          await cache.tags(['artists', 'people']).get<String>('John'),
          isNull,
        );
      });

      test('a flush deletes what the tag lists hold', () async {
        await cache.put('plain', 1);
        await cache.tags(['people', 'artists']).put('John', 1);
        await cache.tags(['artists']).put('Anne', 2);
        await cache.tags(['people']).increment('visits');
        await cache.tags(['people']).flush();
        expect(
          await cache.tags(['people', 'artists']).get<int>('John'),
          isNull,
        );
        expect(await cache.tags(['people']).get<int>('visits'), isNull);
        expect(await cache.tags(['artists']).get<int>('Anne'), 2);
        expect(await cache.get<int>('plain'), 1);
        expect(
          await client.command(['EXISTS', '${prefix}c_tag:people:entries']),
          0,
        );
      });

      test('stale entries leave the lists', () async {
        Clock.freeze();
        final tagged = cache.tags(['news']);
        await tagged.put('old', 1, ttl: const Duration(seconds: 10));
        await tagged.forever('kept', 2);
        Clock.travel(const Duration(seconds: 11));
        await (tagged.store as TaggedCacheStore).flushStale();
        final list = '${prefix}c_tag:news:entries';
        expect(await client.command(['ZRANGE', list, 0, -1]), [
          '${namespace(['news'])}:kept',
        ]);
        await tagged.put('older', 1, ttl: const Duration(seconds: 1));
        Clock.travel(const Duration(seconds: 2));
        expect(
          await (cache.store as RedisStore).flushStaleTags(),
          greaterThanOrEqualTo(1),
        );
        expect(await client.command(['ZCARD', list]), 1);
      });
    });
  }
}
