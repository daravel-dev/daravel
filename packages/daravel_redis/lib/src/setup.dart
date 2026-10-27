import 'package:daravel/daravel.dart';

import 'broadcasting.dart';
import 'client.dart';
import 'config.dart';
import 'queue.dart';
import 'store.dart';
import 'tiered.dart';

/// `withRedis()` on the application builder.
extension RedisApplicationBuilder on ApplicationBuilder {
  /// Adds Redis (or Valkey) to the application, chosen in `.env`:
  ///
  /// - `CACHE_STORE=redis`, `CACHE_LIMITER=redis`,
  ///   `QUEUE_UNIQUE_LOCK_STORE=redis`: [RedisStore] on the `cache`
  ///   connection (`REDIS_CACHE_DB`);
  /// - `CACHE_STORE=tiered`: [TieredStore], each isolate's memory in front
  ///   of Redis, kept exact by `CLIENT TRACKING`;
  /// - `QUEUE_CONNECTION=redis`: [RedisQueue] on the `default` connection
  ///   (`QUEUE_REDIS_ENGINE=stream` for a stream with a consumer group);
  /// - `REDIS_MODE` (or a `redis+sentinel://` / `redis+cluster://`
  ///   `REDIS_URL`): Sentinel or Redis Cluster;
  /// - `REVERB_SCALING_ENABLED=true` with `REVERB_SCALING_DRIVER=redis`:
  ///   broadcasting servers share channels through Redis Pub/Sub;
  /// - the [Redis] facade, a `redis` readiness check on `/up/ready`, and
  ///   a boot warning when a public host is reached without TLS.
  ///
  /// Nothing connects until something uses Redis.
  ApplicationBuilder withRedis() => withConfig<RedisConfig>(RedisConfig.fromEnv)
      .withConfigCheck(RedisConfig.check)
      .withBindings(
        (container) => container.singleton<RedisManager>(
          (c) =>
              RedisManager(c.make<ConfigRepository>().section<RedisConfig>()),
        ),
      )
      .withCacheStore('redis', _redisStore)
      .withCacheStore('tiered', (c) {
        final redis = c.make<ConfigRepository>().section<RedisConfig>();
        final shared = _redisStore(c);
        return TieredStore(
          RedisStore(
            shared.client,
            lockClient: shared.lockClient,
            prefix: '${redis.prefix}tiered:',
            flushPrefix: shared.flushPrefix,
            serializer: redis.serializer,
          ),
          shared: shared,
          maxKeys: redis.tieredMaxKeys,
          maxAge: redis.tieredTtl,
        );
      })
      .withQueueDriver('redis', (c) {
        final config = c.make<ConfigRepository>();
        final redis = config.section<RedisConfig>();
        return RedisQueue(
          c.make<RedisManager>().connection(),
          prefix: redis.prefix,
          namespace: redis.queueNamespace,
          retryAfter: config.section<QueueConfig>().retryAfter,
          engine: redis.queueEngine,
        );
      })
      .withBroadcastScaling('redis', (c, broadcasting, server) {
        final redis = c.make<ConfigRepository>().section<RedisConfig>();
        final client = c.make<RedisManager>().connection();
        final state = RedisChannelState(
          client,
          server: server,
          prefix: redis.prefix,
        );
        return (
          state: state,
          relay: RedisBroadcastRelay(
            client,
            state: state,
            prefix: redis.prefix,
          ),
        );
      })
      .withHealthChecks([
        CallbackHealthCheck('redis', () async {
          final watch = Stopwatch()..start();
          await Redis.command(['PING']);
          return HealthResult.ok({'ms': watch.elapsedMicroseconds / 1000});
        }),
      ])
      .withShutdown((c) async => c.resolved<RedisManager>()?.close());
}

RedisStore _redisStore(Container c) {
  final config = c.make<ConfigRepository>();
  final redis = config.section<RedisConfig>();
  final manager = c.make<RedisManager>();
  return RedisStore(
    manager.connection('cache'),
    lockClient: manager.connection(redis.lockConnection),
    prefix: redis.prefix,
    flushPrefix: config.section<CacheConfig>().prefix,
    serializer: redis.serializer,
  );
}

/// Redis from anywhere in a request, job or command (`Illuminate\Redis`).
abstract final class Redis {
  static RedisManager get manager => Container.current.make<RedisManager>();

  /// The client of connection [name] (`default`, `cache`).
  static RedisClient connection([String name = 'default']) =>
      manager.connection(name);

  /// Any command: `Redis.command(['HSET', 'user:7', 'name', 'Ana'])`.
  static Future<Object?> command(List<Object?> args) =>
      connection().command(args);

  static Future<String?> get(String key) => connection().get(key);

  static Future<bool> set(String key, Object value, {Duration? ttl}) =>
      connection().set(key, value, ttl: ttl);

  static Future<int> del(List<String> keys) => connection().del(keys);

  static Future<Object?> eval(
    RedisScript script, {
    List<String> keys = const [],
    List<Object?> args = const [],
  }) => connection().eval(script, keys: keys, args: args);

  static Future<int> publish(String channel, String message) =>
      connection().publish(channel, message);

  static RedisSubscription subscribe(
    List<String> channels, {
    bool pattern = false,
  }) => connection().subscribe(channels, pattern: pattern);
}
