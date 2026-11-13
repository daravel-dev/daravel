import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

import 'support/store_contract.dart';

/// The `redis` Horizon store against `DARAVEL_TEST_REDIS`: the contract
/// every store meets, then what is the redis store's own (list limits,
/// expiring keys, concurrent writers, the prefix).
void main() {
  test('the store contract is the one daravel_horizon tests its stores '
      'with', () {
    // A copy, since a package cannot import another's tests: the two must
    // stay the same file.
    String read(String path) => File(path).readAsStringSync();
    expect(
      read('test/support/store_contract.dart'),
      read('../daravel_horizon/test/support/store_contract.dart'),
    );
  });

  // No server: the error must come back to the caller (the dashboard's
  // request), not end the process from the root zone where the store
  // works.
  test('monitor, unmonitor and snapshot on an unreachable server throw in '
      "the caller's zone", () async {
    final store = RedisHorizonStore(
      RedisClient(RedisConnectionConfig.fromUrl('redis://127.0.0.1:1')),
      flushEvery: const Duration(hours: 1),
    );
    addTearDown(store.close);
    for (final (name, call) in <(String, Future<void> Function())>[
      ('monitor', () => store.monitor('billing')),
      ('unmonitor', () => store.unmonitor('billing')),
      ('snapshot', store.snapshot),
    ]) {
      await expectLater(
        call().timeout(const Duration(seconds: 10)),
        throwsA(isNot(isA<TimeoutException>())),
        reason: name,
      );
    }
  });

  final url = Platform.environment['DARAVEL_TEST_REDIS'];
  if (url == null || url.isEmpty) {
    test(
      'redis Horizon store (skipped: DARAVEL_TEST_REDIS not set)',
      () {},
      skip: true,
    );
    return;
  }
  final server = RedisConnectionConfig.fromUrl(url);
  // On a Redis Cluster, FLUSHDB and SCAN reach one node: each test has
  // a prefix of its own instead, and the key listing runs standalone.
  final cluster = url.contains('+cluster');
  late String prefix;
  late RedisClient client;
  setUp(() async {
    client = RedisClient(server);
    prefix = 'app${Random().nextInt(1 << 30)}-database-';
    if (!cluster) {
      await client.command(['FLUSHDB']);
    }
  });
  tearDown(() async {
    Clock.restore();
    await client.close();
  });

  String currentPrefix() => prefix;

  RedisHorizonStore make({
    String? prefix,
    int maxPerStatus = 10000,
    AppMetrics? metrics,
  }) => RedisHorizonStore(
    client,
    prefix: prefix ?? currentPrefix(),
    maxPerStatus: maxPerStatus,
    flushEvery: const Duration(hours: 1),
    appMetrics: metrics,
  );

  horizonStoreContract('redis', () async {
    final store = make();
    return (
      store: store as HorizonStore,
      setNow: (DateTime at) => Clock.travelTo(at),
      settle: store.flush,
    );
  });

  final start = DateTime.utc(2026, 11, 12, 9);
  RecordedJob job(
    String uuid, {
    String status = 'completed',
    int later = 0,
    List<String> tags = const [],
  }) => RecordedJob(
    uuid: uuid,
    name: 'SendInvoice',
    queue: 'default',
    status: status,
    at: start.millisecondsSinceEpoch + later,
    tags: tags,
    durationMs: 10,
  );

  Future<List<String>> keys() async {
    final found = <String>[];
    var cursor = '0';
    do {
      final page =
          (await client.command(['SCAN', cursor, 'COUNT', '1000']))!
              as List<Object?>;
      cursor = '${page[0]}';
      found.addAll([for (final k in page[1]! as List<Object?>) '$k']);
    } while (cursor != '0');
    return found;
  }

  test('counts are not cut by the list limit: 10 001 jobs, 10 000 '
      'listed', () async {
    Clock.travelTo(start);
    final store = make(maxPerStatus: 10000);
    for (var i = 0; i < 10001; i++) {
      await store.record(job('j$i', later: i));
    }
    await store.flush();
    Clock.travelTo(start.add(const Duration(seconds: 30)));
    final summary = await store.summary();
    expect(summary['jobs_past_hour'], 10001);
    expect(summary['jobs_per_minute'], 10001);
    expect(
      await client.command([
        'ZCARD',
        '$prefix{daravel:horizon}:jobs:completed',
      ]),
      10000,
    );
    expect(await store.job('j0'), isNull, reason: 'trimmed, hash deleted');
    expect((await store.job('j10000'))?.uuid, 'j10000');
  });

  test('every key carries the prefix and the hash tag, and expires but '
      'the monitored set', () async {
    Clock.travelTo(start);
    final store = make();
    await store.monitor('order:1');
    await store.record(job('a', tags: ['order:1']));
    await store.record(job('b', status: 'failed', later: 1));
    await store.flush();
    await store.snapshot();
    final all = await keys();
    expect(all, isNotEmpty);
    for (final key in all) {
      expect(key, startsWith('$prefix{daravel:horizon}:'));
      final ttl = await client.command(['PTTL', key]);
      if (key.endsWith(':monitored')) {
        expect(ttl, -1, reason: key);
      } else {
        expect(ttl, greaterThan(0), reason: '$key has no TTL');
      }
    }
  }, skip: cluster ? 'SCAN reaches one node of a cluster' : false);

  test('the Laravel Horizon and other keys are not touched', () async {
    await client.command(['SET', 'laravel_horizon:supervisors', 'x']);
    await client.command(['SET', 'other', 'y']);
    final store = make();
    await store.record(job('a'));
    await store.flush();
    await store.snapshot();
    expect(await client.command(['GET', 'laravel_horizon:supervisors']), 'x');
    expect(await client.command(['GET', 'other']), 'y');
  });

  test('two stores writing the same job at once lose no other record, '
      'and the newest wins', () async {
    Clock.travelTo(start);
    final a = make();
    final b = RedisHorizonStore(
      RedisClient(server),
      prefix: prefix,
      flushEvery: const Duration(hours: 1),
    );
    addTearDown(() => b.client.close());
    for (var round = 0; round < 10; round++) {
      for (var i = 0; i < 99; i++) {
        await a.record(job('a$round-$i'));
        await b.record(job('b$round-$i'));
      }
      await a.record(job('x$round', status: 'failed'));
      await b.record(job('x$round', later: 1));
      await Future.wait([a.flush(), b.flush()]);
    }
    expect(
      await client.command(['ZCARD', '$prefix{daravel:horizon}:recent']),
      10 * (99 + 99 + 1),
    );
    for (var round = 0; round < 10; round++) {
      expect((await a.job('x$round'))?.status, 'completed');
    }
    Clock.travelTo(start.add(const Duration(seconds: 10)));
    final summary = await a.summary();
    // x: failed once and completed once, each counted.
    expect(summary['jobs_per_minute'], 10 * (99 + 99 + 2));
    expect(summary['failed_past_week'], 10);
  });

  test('a job trimmed off every list loses its hash; one still listed '
      'keeps it', () async {
    Clock.travelTo(start);
    final store = make(maxPerStatus: 2);
    await store.record(job('f', status: 'failed'));
    for (var i = 0; i < 3; i++) {
      await store.record(job('c$i', later: 1 + i));
    }
    await store.flush();
    // c0 was trimmed from completed and from recent (max 2 each).
    expect(await store.job('c0'), isNull);
    expect((await store.job('c2'))?.uuid, 'c2');
    // f left recent too, but is still in the failed list.
    expect((await store.job('f'))?.status, 'failed');
  });

  // Documents a known limit: "counts once per job and status" is
  // remembered in the job's hash, so a duplicate arriving after the hash
  // was trimmed counts again.
  test('a duplicate after its job was trimmed counts again '
      '(documented)', () async {
    Clock.travelTo(start);
    final store = make(maxPerStatus: 1);
    await store.record(job('a'));
    await store.record(job('b', later: 1));
    await store.flush();
    expect(await store.job('a'), isNull, reason: 'trimmed');
    await store.record(job('a'));
    await store.flush();
    Clock.travelTo(start.add(const Duration(seconds: 5)));
    expect((await store.summary())['jobs_per_minute'], 3);
  });

  test('a write that fails is dropped and counted, never thrown', () async {
    final metrics = AppMetrics(MetricsRegistry());
    final broken = RedisHorizonStore(
      RedisClient(RedisConnectionConfig.fromUrl('redis://127.0.0.1:1')),
      flushEvery: const Duration(hours: 1),
      appMetrics: metrics,
    );
    await broken.record(job('a'));
    await broken.flush();
    expect(
      metrics.registry.counter('horizon_store_dropped_total', '').value({
        'store': 'redis',
        'reason': 'error',
      }),
      1,
    );
    await broken.close();
    await broken.record(job('b'));
    expect(
      metrics.registry.counter('horizon_store_dropped_total', '').value({
        'store': 'redis',
        'reason': 'closed',
      }),
      1,
    );
  });
}
