@Tags(['integration'])
library;

import 'dart:io';
import 'dart:math';

import 'package:daravel_redis/daravel_redis.dart';
import 'package:test/test.dart';

/// `RedisChannelState` per worker isolate (#153): a re-subscribe is not a
/// new member, and a respawned worker forgets what its previous life left.
void main() {
  final url = Platform.environment['DARAVEL_TEST_REDIS'];
  if (url == null || url.isEmpty) {
    test(
      'Redis channel state (skipped: DARAVEL_TEST_REDIS not set)',
      () {},
      skip: true,
    );
    return;
  }

  late String prefix;
  late RedisClient client;

  setUp(() {
    prefix = 'bstate_${Random().nextInt(1 << 32)}_';
    client = RedisClient(RedisConnectionConfig.fromUrl(url));
  });

  tearDown(() async {
    final keys = await client.scan(match: '$prefix*').toList();
    if (keys.isNotEmpty) {
      await client.del(keys);
    }
    await client.close();
  });

  RedisChannelState state(String worker) => RedisChannelState(
    client,
    server: 'host:1',
    worker: worker,
    prefix: prefix,
  );

  Future<Map<Object?, Object?>> join(
    RedisChannelState state,
    String socket,
  ) async =>
      (await state.call('join', {
            'channel': 'presence-room',
            'socket': socket,
            'user_id': '7',
            'user_info': {'name': 'Teo'},
          }))!
          as Map;

  Future<Map<Object?, Object?>> info(RedisChannelState state) async =>
      (await state.call('channel', {'channel': 'presence-room'}))! as Map;

  test('subscribing again is not a new member', () async {
    final worker = state('daravel-worker-1');
    await worker.beat();
    expect((await join(worker, '1.1'))['added'], isTrue);
    expect((await join(worker, '1.1'))['added'], isFalse);
    expect((await info(worker))['subscription_count'], 1);
    expect(
      (await worker.call('leave', {
        'channel': 'presence-room',
        'socket': '1.1',
      }))!,
      {'removed': '7'},
    );
  });

  test('a respawned worker forgets its previous life', () async {
    final crashed = state('daravel-worker-1');
    await crashed.beat();
    await join(crashed, '1.1');
    final sibling = state('daravel-worker-2');
    await sibling.beat();
    await join(sibling, '2.2');
    expect((await info(sibling))['subscription_count'], 2);

    // Same name, new isolate: its first beat drops the old connections.
    final respawned = state('daravel-worker-1');
    await respawned.beat();
    expect((await info(respawned))['subscription_count'], 1);
    expect(respawned.instance, 'host:1/daravel-worker-1');
  });
}
