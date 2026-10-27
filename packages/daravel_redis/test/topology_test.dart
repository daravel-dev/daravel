import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

/// Sentinel and Cluster (`tool/topologies.sh` starts both): the cluster
/// tests run with `DARAVEL_TEST_REDIS_CLUSTER`
/// (`redis+cluster://127.0.0.1:17001`), the Sentinel ones with
/// `DARAVEL_TEST_REDIS_SENTINEL` (`redis+sentinel://127.0.0.1:17020/mymaster`).
void main() {
  group('hash slots', () {
    test("CRC16 as Redis Cluster's specification", () {
      expect(redisHashSlot('123456789'), 12739);
      expect(redisHashSlot('foo'), 12182);
      expect(redisHashSlot(''), 0);
    });

    test('a hash tag puts keys together', () {
      expect(
        redisHashSlot('{user1000}.following'),
        redisHashSlot('{user1000}.followers'),
      );
      expect(redisHashSlot('{user1000}.following'), redisHashSlot('user1000'));
      // An empty tag does not count: the whole key is hashed.
      expect(redisHashSlot('foo{}{bar}'), isNot(redisHashSlot('bar')));
      expect(redisHashSlot('foo{{bar}}'), redisHashSlot('{bar'));
      expect(
        redisHashSlot('daravel:queue:{default}:notify'),
        redisHashSlot('default'),
      );
    });

    test('keys of a command, for routing', () {
      final keys = RedisClusterClient.keysOf;
      expect(keys(['GET', 'a']), ['a']);
      expect(keys(['PING']), isEmpty);
      expect(keys(['PUBLISH', 'news', 'x']), isEmpty);
      expect(keys(['EVALSHA', 'sha', 2, 'k1', 'k2', 'arg']), ['k1', 'k2']);
      expect(keys(['EVAL', 'return 1', 0]), isEmpty);
      expect(keys(['BLPOP', 'a', 'b', '1.000']), ['a', 'b']);
      expect(keys(['MSET', 'a', '1', 'b', '2']), ['a', 'b']);
      expect(
        keys([
          'XREADGROUP',
          'GROUP',
          'g',
          'c',
          'STREAMS',
          's1',
          's2',
          '>',
          '>',
        ]),
        ['s1', 's2'],
      );
      expect(keys(['XGROUP', 'CREATE', 's', 'g', r'$']), ['s']);
    });
  });

  group('URLs', () {
    test(
      'redis+sentinel:// lists the Sentinels, the service and the database',
      () {
        final config = RedisConnectionConfig.fromUrl(
          'redis+sentinel://:s3cret@10.0.0.1:26379,10.0.0.2/mymaster/2',
        );
        expect(config.mode, RedisMode.sentinel);
        expect(config.nodes, [
          (host: '10.0.0.1', port: 26379),
          (host: '10.0.0.2', port: 26379),
        ]);
        expect(config.sentinelService, 'mymaster');
        expect(config.database, 2);
        expect(config.password, 's3cret');
        expect(config.redacted, isNot(contains('s3cret')));
        expect(
          config.redacted,
          'redis+sentinel://********@10.0.0.1:26379,10.0.0.2:26379/mymaster/2',
        );
      },
    );

    test('redis+cluster:// lists its nodes; rediss turns TLS on', () {
      final config = RedisConnectionConfig.fromUrl(
        'rediss+cluster://app:pw@node-a:7000,[::1]:7001',
      );
      expect(config.mode, RedisMode.cluster);
      expect(config.tls, isTrue);
      expect(config.username, 'app');
      expect(config.nodes, [
        (host: 'node-a', port: 7000),
        (host: '::1', port: 7001),
      ]);
      expect(config.database, 0);
    });

    test('a Sentinel URL without its service is refused', () {
      expect(
        () => RedisConnectionConfig.fromUrl('redis+sentinel://h:26379'),
        throwsA(isA<ConfigException>()),
      );
    });

    test('REDIS_MODE and REDIS_NODES, without a URL', () {
      final config = RedisConnectionConfig.fromEnv(
        Env.fromMap({
          'REDIS_MODE': 'sentinel',
          'REDIS_NODES': 'a,b:26380',
          'REDIS_SENTINEL_SERVICE': 'cache',
          'REDIS_SENTINEL_PASSWORD': 'sp',
          'REDIS_DB': '3',
        }),
      );
      expect(config.mode, RedisMode.sentinel);
      expect(config.nodes, [
        (host: 'a', port: 26379),
        (host: 'b', port: 26380),
      ]);
      expect(config.sentinelService, 'cache');
      expect(config.sentinelPassword, 'sp');
      expect(config.database, 3);
      expect(config.node('a', 26379, sentinel: true).password, 'sp');
      expect(config.node('m', 6379).database, 3);
    });

    test('a cluster always uses database 0', () {
      final config = RedisConnectionConfig.fromEnv(
        Env.fromMap({'REDIS_URL': 'redis+cluster://n:7000'}),
        database: 1,
      );
      expect(config.database, 0);
    });
  });

  _cluster();
  _sentinel();
}

String _prefix() => 'test_${Random().nextInt(1 << 32)}_';

void _cluster() {
  final url = Platform.environment['DARAVEL_TEST_REDIS_CLUSTER'];
  if (url == null || url.isEmpty) {
    test(
      'Redis Cluster (skipped: DARAVEL_TEST_REDIS_CLUSTER not set)',
      () {},
      skip: true,
    );
    return;
  }
  group('cluster', tags: ['integration'], () {
    late RedisClusterClient client;
    late String prefix;
    setUp(() {
      prefix = _prefix();
      client =
          RedisClient(RedisConnectionConfig.fromUrl(url)) as RedisClusterClient;
    });
    tearDown(() async {
      final keys = await client.scan(match: '$prefix*').toList();
      if (keys.isNotEmpty) {
        await client.del(keys);
      }
      await client.close();
    });

    test('every key reaches the master of its slot', () async {
      final keys = [for (var i = 0; i < 60; i++) '$prefix$i'];
      expect({for (final k in keys) client.slot(k)}.length, greaterThan(1));
      await Future.wait([for (final k in keys) client.set(k, k)]);
      expect(await client.masters(), hasLength(3));
      // Split per slot, put back in order.
      expect(await client.command(['MGET', ...keys]), keys);
      expect(await client.command(['EXISTS', ...keys]), keys.length);
      expect(await client.scan(match: '$prefix*').length, keys.length);
      expect(await client.del(keys.sublist(0, 30)), 30);
      expect(
        ((await client.command(['MGET', ...keys]))! as List)
            .whereType<String>(),
        hasLength(30),
      );
    });

    test('a script whose keys share a hash tag runs on their master', () async {
      final script = RedisScript(
        "redis.call('SET', KEYS[1], ARGV[1]); "
        "return redis.call('INCRBY', KEYS[2], ARGV[1])",
      );
      final tag = '$prefix{user:7}';
      expect(
        await client.eval(script, keys: ['$tag:a', '$tag:b'], args: [5]),
        5,
      );
      expect(
        () =>
            client.eval(script, keys: ['${prefix}x', '${prefix}y'], args: [1]),
        throwsA(
          isA<RedisCommandException>().having(
            (e) => e.code,
            'code',
            'CROSSSLOT',
          ),
        ),
      );
    });

    test('the store, its flush, locks and rate limits', () async {
      final store = RedisStore(client, prefix: prefix, flushPrefix: 'c:');
      await store.putMany({for (var i = 0; i < 20; i++) 'c:$i': i});
      await client.set('${prefix}keep', '1');
      expect((await store.many(['c:1', 'c:19', 'c:none'])), {
        'c:1': 1,
        'c:19': 19,
        'c:none': null,
      });
      await store.flush();
      expect(await store.get('c:1'), isNull);
      expect(await client.get('${prefix}keep'), '1');

      expect(
        await store.acquireLock('l', 'a', const Duration(seconds: 5)),
        isTrue,
      );
      expect(
        await store.acquireLock('l', 'b', const Duration(seconds: 5)),
        isFalse,
      );
      expect(await store.releaseLock('l', 'a'), isTrue);

      final hits = [
        for (var i = 0; i < 3; i++)
          (await store.hitWindow('rl', 2, const Duration(seconds: 5))).allowed,
      ];
      expect(hits, [true, true, false]);
    });

    for (final engine in RedisQueueEngine.values) {
      test('queues on different slots, one worker waiting on both (${engine.name})', () async {
        final queue = RedisQueue(client, prefix: prefix, engine: engine);
        final a = client.slot(
          '${prefix}daravel:${engine == RedisQueueEngine.list ? 'queue' : 'stream'}:{alpha}:notify',
        );
        final b = client.slot(
          '${prefix}daravel:${engine == RedisQueueEngine.list ? 'queue' : 'stream'}:{beta}:notify',
        );
        expect(a, isNot(b));
        final watch = Stopwatch()..start();
        final waiting = queue.waitForWork([
          'alpha',
          'beta',
        ], const Duration(seconds: 10));
        await Future<void>.delayed(const Duration(milliseconds: 200));
        final b1 = await queue.push(_payload(), queue: 'beta');
        await waiting;
        expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
        expect((await queue.pop('beta'))?.id, b1);

        // The wait still pending on alpha takes the next token.
        final a1 = await queue.push(_payload(), queue: 'alpha');
        await queue.waitForWork(['alpha', 'beta'], const Duration(seconds: 10));
        expect((await queue.pop('alpha'))?.id, a1);
        expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
        await queue.stopWaiting();
        await queue.clear('alpha');
        await queue.clear('beta');
      });
    }

    test('sharded Pub/Sub follows its shard when the slot moves', () async {
      final channel = '$prefix{orders}:created';
      expect(
        () => client.subscribe([channel, '${prefix}other'], sharded: true),
        throwsArgumentError,
      );
      final subscription = client.subscribe([
        channel,
        '$prefix{orders}:paid',
      ], sharded: true);
      final received = <String>[];
      subscription.messages.listen((m) => received.add(m.payload));
      await subscription.ready;
      final publisher = RedisClient(client.config) as RedisClusterClient;
      addTearDown(publisher.close);
      expect(await publisher.publish(channel, 'one', sharded: true), 1);

      final slot = client.slot(channel);
      final masters = await client.masters();
      final owner = await _ownerOf(masters, slot);
      final target = masters.firstWhere((m) => m != owner);
      await _startMove(masters, slot, owner, target);
      await _finishMove(masters, slot, target);
      try {
        // The old owner unsubscribed us; the subscription follows the slot.
        final until = DateTime.now().add(const Duration(seconds: 10));
        while (!received.contains('two')) {
          if (DateTime.now().isAfter(until)) {
            fail('no message after the slot moved: $received');
          }
          await publisher.refresh();
          await publisher.publish(channel, 'two', sharded: true);
          await Future<void>.delayed(const Duration(milliseconds: 200));
        }
      } finally {
        await _startMove(masters, slot, target, owner);
        await _finishMove(masters, slot, owner);
        await subscription.cancel();
      }
      expect(received.first, 'one');
    });

    test('ASK while a slot migrates, MOVED once it moved', () async {
      final key = '${prefix}migrating';
      final slot = client.slot(key);
      final masters = await client.masters();
      await client.command(['GET', key]); // reads the map
      final owner = await _ownerOf(masters, slot);
      final target = masters.firstWhere((m) => m != owner);
      Future<void> move(String from, String to) =>
          _startMove(masters, slot, from, to);
      Future<void> finish(String to) => _finishMove(masters, slot, to);

      await move(owner, target);
      try {
        // The old owner answers ASK for a key it does not hold.
        expect(await client.set(key, 'v'), isTrue);
        expect(await client.get(key), 'v');
        final asked = client.stats['redirects']! as int;
        expect(asked, greaterThanOrEqualTo(2));
        await finish(target);
        // The client's map still names the old owner: MOVED, then the map
        // is right again.
        expect(await client.get(key), 'v');
        expect(client.stats['redirects']! as int, greaterThan(asked));
        expect(await client.del([key]), 1);
      } finally {
        await _node(target, ['DEL', key]);
        await move(target, owner);
        await finish(owner);
      }
      await client.refresh();
      expect(await _ownerOf(masters, slot), owner);
    });
  });
}

/// Starts moving an empty [slot] (`IMPORTING`, `MIGRATING`).
Future<void> _startMove(
  List<String> masters,
  int slot,
  String from,
  String to,
) async {
  final ids = {
    for (final m in masters) m: await _node(m, ['CLUSTER', 'MYID']),
  };
  await _node(to, ['CLUSTER', 'SETSLOT', slot, 'IMPORTING', ids[from]]);
  await _node(from, ['CLUSTER', 'SETSLOT', slot, 'MIGRATING', ids[to]]);
}

/// Gives [slot] to [to] on every master.
Future<void> _finishMove(List<String> masters, int slot, String to) async {
  final id = await _node(to, ['CLUSTER', 'MYID']);
  await _node(to, ['CLUSTER', 'SETSLOT', slot, 'NODE', id]);
  for (final m in masters.where((m) => m != to)) {
    await _node(m, ['CLUSTER', 'SETSLOT', slot, 'NODE', id]);
  }
}

Future<Object?> _node(String address, List<Object?> args) async {
  final colon = address.lastIndexOf(':');
  final client = RedisClient(
    RedisConnectionConfig(
      host: address.substring(0, colon),
      port: int.parse(address.substring(colon + 1)),
    ),
  );
  try {
    return await client.command(args);
  } finally {
    await client.close();
  }
}

Future<String> _ownerOf(List<String> masters, int slot) async {
  for (final m in masters) {
    final ranges = (await _node(m, ['CLUSTER', 'SLOTS']))! as List;
    for (final range in ranges) {
      if (range
          case [
            final int start,
            final int end,
            [final String host, final int port, ...],
            ...,
          ]
          when slot >= start && slot <= end) {
        return '${host.isEmpty ? m.substring(0, m.lastIndexOf(':')) : host}:$port';
      }
    }
  }
  throw StateError('slot $slot has no owner');
}

JobPayload _payload() => JobPayload.forJob(const _Ping());

final class _Ping extends Job {
  const _Ping();

  @override
  String get jobName => 'ping';

  @override
  Map<String, Object?> toJson() => const {};

  @override
  Future<void> handle(JobContext context) async {}
}

void _sentinel() {
  final url = Platform.environment['DARAVEL_TEST_REDIS_SENTINEL'];
  if (url == null || url.isEmpty) {
    test(
      'Redis Sentinel (skipped: DARAVEL_TEST_REDIS_SENTINEL not set)',
      () {},
      skip: true,
    );
    return;
  }
  group('sentinel', tags: ['integration'], () {
    final config = RedisConnectionConfig.fromUrl(url);
    late RedisClient client;
    late String prefix;
    setUp(() {
      prefix = _prefix();
      client = RedisClient(config);
    });
    tearDown(() async {
      final keys = await client.scan(match: '$prefix*').toList();
      if (keys.isNotEmpty) {
        await client.del(keys);
      }
      await client.close();
    });

    Future<String> master() async {
      final sentinel = config.nodes.first;
      final reply = await _node('${sentinel.host}:${sentinel.port}', [
        'SENTINEL',
        'get-master-addr-by-name',
        config.sentinelService,
      ]);
      final [host, port] = (reply! as List).cast<Object?>();
      return '$host:$port';
    }

    test('commands reach the master Sentinel names', () async {
      expect(await client.set('${prefix}a', '1'), isTrue);
      expect(client.stats['server'], await master());
      expect(await client.get('${prefix}a'), '1');
    });

    test('after a failover, writes reach the new master', () async {
      expect(await client.set('${prefix}before', '1'), isTrue);
      final old = await master();
      final sentinel = config.nodes.first;
      await _node('${sentinel.host}:${sentinel.port}', [
        'SENTINEL',
        'FAILOVER',
        config.sentinelService,
      ]);
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (await master() == old) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Sentinel did not fail over');
        }
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      final promoted = await master();
      // Until Sentinel turns the old master into a replica (and drops its
      // clients), writes may still land there: Redis's own window of lost
      // writes. Once it has, every write reaches the new master, and none
      // is lost to a replica (READONLY is sent again).
      final until = DateTime.now().add(const Duration(seconds: 20));
      while (client.stats['server'] != promoted) {
        if (DateTime.now().isAfter(until)) {
          fail('writes still reach ${client.stats['server']}');
        }
        try {
          expect(await client.set('${prefix}after', '2'), isTrue);
        } on RedisConnectionException {
          // The old master dropped this client: the next write reconnects.
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(await client.set('${prefix}after', '3'), isTrue);
      expect(client.stats['server'], promoted);
      expect(await client.get('${prefix}before'), '1');
    }, timeout: const Timeout(Duration(seconds: 60)));
  });
}
