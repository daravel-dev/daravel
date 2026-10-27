// The Daravel side of bench/interop/redis.sh: one step per run, against the
// Redis a Laravel application uses too (REDIS_*, CACHE_PREFIX).
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_redis/daravel_redis.dart';

Future<void> main(List<String> args) async {
  final app = Application.configure(basePath: Directory.current.path)
      .withRedis()
      .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
      .create();
  await app.boot();
  final out = await app.run(() async {
    switch (args.first) {
      case 'lock':
        // Takes the lock if it is free; prints whether, and its owner.
        final lock = Cache.lock('report', ttl: const Duration(seconds: 30));
        final got = await lock.acquire();
        final owner = await Cache.store().store.lockOwner(
          '${Cache.store().prefix}report',
        );
        return 'acquired=$got owner=$owner mine=${lock.owner}';
      case 'release':
        await Cache.store().store.forceReleaseLock(
          '${Cache.store().prefix}report',
        );
        return 'released';
      case 'get':
        return 'visits=${await Cache.get<int>('visits')}';
      case 'increment':
        return 'visits=${await Cache.increment('visits')}';
      case 'profile':
        return jsonEncode(await Cache.get<Object?>('profile'));
      case 'put-profile':
        await Cache.put('profile', {
          'name': 'Bo',
          'tags': ['x'],
          'none': null,
        }, ttl: const Duration(minutes: 1));
        return 'stored';
    }
    return 'unknown step';
  });
  stdout.writeln(out);
  await app.shutdown();
}
