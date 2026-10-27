@Tags(['integration'])
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

/// Two "servers" (clients of their own) sharing Redis through
/// [TieredStore]: what one writes, the other's L1 drops. Runs against
/// `DARAVEL_TEST_REDIS` and, when set, `DARAVEL_TEST_REDIS_CLUSTER`.
void main() {
  for (final (name, variable) in [
    ('server', 'DARAVEL_TEST_REDIS'),
    ('cluster', 'DARAVEL_TEST_REDIS_CLUSTER'),
  ]) {
    final url = Platform.environment[variable];
    if (url == null || url.isEmpty) {
      test('tiered on a $name (skipped: $variable not set)', () {}, skip: true);
      continue;
    }
    group('tiered on a $name', () {
      final config = RedisConnectionConfig.fromUrl(url);
      late String prefix;
      late RedisClient first;
      late RedisClient second;
      late TieredStore a;
      late TieredStore b;

      TieredStore tiered(RedisClient client) => TieredStore(
        RedisStore(client, prefix: '${prefix}tiered:'),
        shared: RedisStore(client, prefix: prefix),
        maxKeys: 3,
      );

      Future<void> live(TieredStore store) async {
        await store.get('warm-up');
        for (var i = 0; i < 100 && !store.invalidations.live; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(store.invalidations.live, isTrue);
      }

      /// Until [read] gives [expected], at most a second (invalidations
      /// travel on a connection of their own).
      Future<void> eventually(
        Future<Object?> Function() read,
        Object? expected,
      ) async {
        Object? last;
        for (var i = 0; i < 50; i++) {
          last = await read();
          if (last == expected) {
            return;
          }
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(last, expected);
      }

      setUp(() async {
        prefix = 'test_${Random().nextInt(1 << 32)}_';
        first = RedisClient(config);
        second = RedisClient(config);
        a = tiered(first);
        b = tiered(second);
        await live(a);
        await live(b);
      });

      tearDown(() async {
        final keys = await first.scan(match: '$prefix*').toList();
        if (keys.isNotEmpty) {
          await first.del(keys);
        }
        await first.close();
        await second.close();
      });

      test('reads come from L1 until another server writes', () async {
        await b.put('user:7', {'name': 'Ana'});
        // Its invalidation first: a read it overtakes is not kept in L1.
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(await a.get('user:7'), {'name': 'Ana'});
        final hits = a.stats['hits']! as int;
        expect(await a.get('user:7'), {'name': 'Ana'});
        expect(a.stats['hits'], hits + 1);

        await b.put('user:7', {'name': 'Bo'});
        await eventually(() => a.get('user:7'), {'name': 'Bo'});
        await b.forget('user:7');
        await eventually(() => a.get('user:7'), null);
      });

      test('own writes are seen at once', () async {
        expect(await a.get('n'), isNull);
        await a.put('n', 1);
        expect(await a.get('n'), 1);
        expect(await a.increment('n', 4), 5);
        expect(await a.get('n'), 5);
      });

      test('L1 keeps Redis expiry and its size', () async {
        await a.put('short', 'x', ttl: const Duration(milliseconds: 200));
        expect(await a.get('short'), 'x');
        await Future<void>.delayed(const Duration(milliseconds: 260));
        expect(await a.get('short'), isNull);

        for (final key in ['k1', 'k2', 'k3', 'k4']) {
          await a.put(key, key);
          await a.get(key);
        }
        expect(a.stats['entries'], lessThanOrEqualTo(3));
      });

      test('a flush on one server empties the other L1', () async {
        await a.put('f', 'x');
        expect(await b.get('f'), 'x');
        await a.flush();
        await eventually(() => b.get('f'), null);
      });

      test('racing writes: L1 ends with the last value', () async {
        await b.put('race', 0);
        await a.get('race');
        await Future.wait([
          for (var i = 1; i <= 50; i++) ...[b.put('race', i), a.get('race')],
        ]);
        await b.put('race', 'final');
        await eventually(() => a.get('race'), 'final');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(await a.get('race'), 'final');
      });

      test('locks and rate limits are the shared store', () async {
        expect(
          await a.acquireLock('job', 'one', const Duration(seconds: 5)),
          isTrue,
        );
        expect(await b.lockOwner('job'), 'one');
        expect(
          (await b.hitGcra('login', 1, const Duration(seconds: 5))).allowed,
          isTrue,
        );
        expect(
          (await a.hitGcra('login', 1, const Duration(seconds: 5))).allowed,
          isFalse,
        );
      });
    });
  }
}
