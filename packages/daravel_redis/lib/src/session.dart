import 'package:daravel/daravel.dart';
import 'package:daravel_session/daravel_session.dart';

import 'client.dart';
import 'config.dart';
import 'serializer.dart';
import 'store.dart';

/// `SESSION_DRIVER=redis`, Laravel's `redis` session driver
/// (`SessionManager::createRedisDriver`): a [CacheSessionHandler] over a
/// [RedisStore] on the `SESSION_CONNECTION` connection (`default` when
/// unset, as Laravel's `RedisManager::connection(null)`), so a session is
/// the key `<REDIS_PREFIX><CACHE_PREFIX><id>` holding `serialize($payload)`
/// for `SESSION_LIFETIME` minutes (`SETEX`), and a Laravel application with
/// the same prefixes and `APP_KEY` shares it.
///
/// The value is always written with PHP's `serialize()`, as Laravel's
/// `RedisStore::serialize` writes it, whatever `REDIS_SERIALIZER` says for
/// the cache; Daravel reads JSON values too.
CacheSessionHandler redisSessionHandler(
  Container container,
  SessionConfig session,
) {
  final config = container.make<ConfigRepository>();
  final redis = config.section<RedisConfig>();
  final cachePrefix = config.section<CacheConfig>().prefix;
  final manager = container.make<RedisManager>();
  return CacheSessionHandler(
    CacheRepository(
      RedisStore(
        manager.connection(session.connection ?? 'default'),
        lockClient: manager.connection(redis.lockConnection),
        prefix: redis.prefix,
        flushPrefix: cachePrefix,
        serializer: RedisSerializer.php,
      ),
      prefix: cachePrefix,
    ),
    lifetime: session.lifetime,
  );
}

/// Refuses `SESSION_DRIVER=redis` with a `SESSION_CONNECTION` that is not a
/// configured Redis connection, at boot rather than on the first request.
Iterable<ConfigIssue> checkRedisSessions(
  Env env,
  ConfigRepository config,
) sync* {
  if (!config.hasSection<SessionConfig>()) {
    return;
  }
  final session = config.section<SessionConfig>();
  if (session.driver != 'redis') {
    return;
  }
  final name = session.connection ?? 'default';
  final connections = config.section<RedisConfig>().connections;
  if (!connections.containsKey(name)) {
    yield ConfigIssue(
      ConfigIssueLevel.error,
      'SESSION_CONNECTION=$name is not a Redis connection '
      '(${connections.keys.join(', ')}).',
    );
  }
}
