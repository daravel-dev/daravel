# Changelog

## 1.18.1

- Version aligned with Daravel 1.18.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.18.0

- Version aligned with Daravel 1.18.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.17.0

- Version aligned with Daravel 1.17.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.16.0

- Version aligned with Daravel 1.16.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.15.0

- Version aligned with Daravel 1.15.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.14.0

- Version aligned with Daravel 1.14.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.13.0

- Version aligned with Daravel 1.13.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.12.0

- First release: `withRedis()`, a RESP client (`RedisClient`, `RedisScript`, Pub/Sub), `RedisStore` (cache, Laravel-compatible locks, one-script rate limits), `RedisQueue` (`BLPOP` wake-up), broadcasting between servers (`RedisBroadcastRelay`, `RedisChannelState`), the `Redis` facade and a `redis` readiness check.
- Sentinel (`RedisMode.sentinel`, `redis+sentinel://`: master discovery, `ROLE` check, `READONLY` resent after a failover) and Redis Cluster (`RedisClusterClient`, `redis+cluster://`: slot map, `MOVED`, `ASK`, `TRYAGAIN`, keys of several slots split for `MGET`/`DEL`/`UNLINK`/`EXISTS`/`TOUCH`, `SCAN` on every master); `redisHashSlot`; `RedisClient.pipeline`, `scan`, `stats`.
- `TieredStore` (`CACHE_STORE=tiered`): an L1 per isolate kept exact by `CLIENT TRACKING ... BCAST` (`RedisInvalidations`), on one server or a cluster.
- `RedisQueueEngine.stream` (`QUEUE_REDIS_ENGINE=stream`): a stream with a consumer group, `XAUTOCLAIM` for jobs whose worker died.
- `RedisSerializer.php` (`REDIS_SERIALIZER=php`) and `PhpSerializer`: cached values as Laravel's `serialize()`, read either way.
- `RateCounterStore` on `RedisStore`: `Limit.slidingWindow()` and `Limit.gcra()`, one script each on the server's clock.
- `redisCommands` (`package:daravel_redis/commands.dart`): `redis:ping`, `redis:stats`, `redis:keys-audit`, `redis:cli` (read-only unless `--write`), `redis:inspect` with the MCP tool `redis_inspect`, `cache:prune-stale-tags`.
- `RedisStore.tags` (`RedisTaggedCacheStore`, Laravel 12's keys and tag lists) and `flushStaleTags`; `TieredStore` tags with tag ids.
- `Redis.throttle` and `Redis.funnel` (`RedisDurationLimiter`, `RedisConcurrencyLimiter`, `LimiterTimeoutException`), Laravel's scripts and keys.
- Sharded Pub/Sub: `publish(..., sharded: true)`, `subscribe([...], sharded: true)`, following its slot in a cluster.
- `Redis.events(channel)` (`RedisEventStream`): server-sent events kept in a stream, resumed from `Last-Event-ID`.
