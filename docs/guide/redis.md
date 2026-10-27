# Redis

On one server Daravel needs no Redis: the coordinator isolate keeps the
cache, locks and rate limits for every worker isolate in memory, and the
database queue is ACID. `daravel_redis` is for several servers, where that
state has to be shared and the database becomes the bottleneck.

| Your setup | Use |
| :-- | :-- |
| One VPS or one container | The defaults (`CACHE_STORE=process`, the database queue). Do not add Redis |
| Several servers, little traffic, PostgreSQL or MySQL already there | `CACHE_STORE=database`, the database queue, `REVERB_SCALING_ENABLED` on the database. Still no Redis |
| Several servers with tight latency, strict rate limits, many jobs or WebSockets across servers, or a Laravel app on Redis already | `daravel_redis` |

It works with Redis 6.2 or newer and with Valkey, and speaks the protocol
itself (no native library).

## Installing

```bash
dart pub add daravel_redis
```

```dart
// bootstrap/app.dart
import 'package:daravel_redis/daravel_redis.dart';

Application createApp() => Application.configure(basePath: basePath)
    .withRedis()
    // ...
    .create();
```

`withRedis()` registers everything below; nothing connects until
something uses Redis, so it costs nothing while `.env` does not ask for it.

## Choosing it in `.env`

```dotenv
REDIS_HOST=10.0.0.15
REDIS_PASSWORD=secret
# or REDIS_URL=rediss://user:secret@redis.example.com:6380/0

CACHE_STORE=redis          # cache, locks, the JWT denylist
CACHE_LIMITER=redis        # rate limits, one round trip each
QUEUE_CONNECTION=redis     # jobs picked up as soon as they are pushed

REVERB_SCALING_ENABLED=true
REVERB_SCALING_DRIVER=redis  # broadcasting servers share Echo's clients
```

| Setting | What Redis does |
| :-- | :-- |
| `CACHE_STORE=redis` | `Cache` and `Cache.lock` on every server. Logout (`Auth.jwtGuard().invalidate()`) reaches every server too, since the JWT denylist lives in the default store |
| `CACHE_LIMITER=redis` | Each attempt is one Lua script; blocked attempts are not counted |
| `QUEUE_CONNECTION=redis` | Jobs in Redis; an idle worker blocks on `BLPOP` and starts a pushed job at once instead of after `--sleep`. Unique-job locks and `queue:restart` / `queue:pause` go to Redis as well (`QUEUE_UNIQUE_LOCK_STORE=redis`) |
| `REVERB_SCALING_DRIVER=redis` | Frames between servers over Pub/Sub; presence members, the channels API and cache channels in Redis ([Broadcasting](broadcasting.md#several-servers)) |

The cache uses the `cache` connection (`REDIS_CACHE_DB`, 1 by default), so
`dartisan cache:clear` deletes only the cache's keys (`SCAN` and `UNLINK`
on its prefix, never `FLUSHDB`) and never queued jobs.

## Configuration

| Variable | Default | Purpose |
| :-- | :-- | :-- |
| `REDIS_URL` | none | `redis://` or `rediss://` (TLS), `user:password@host:port/database`; replaces the variables below |
| `REDIS_HOST`, `REDIS_PORT` | `127.0.0.1`, `6379` | The server |
| `REDIS_USERNAME`, `REDIS_PASSWORD` | none | ACL user (Redis 6+) and password |
| `REDIS_DB`, `REDIS_CACHE_DB` | `0`, `1` | Databases of the `default` and `cache` connections, as in Laravel |
| `REDIS_PREFIX` | `<app>-database-` | Put before every key, Laravel 12's default |
| `REDIS_CACHE_LOCK_CONNECTION` | `default` | Where cache locks live, as Laravel's `lock_connection` |
| `REDIS_TLS` | `false` | TLS without `rediss://`; boot warns when a public host goes without it |
| `REDIS_COMMAND_TIMEOUT`, `REDIS_CONNECT_TIMEOUT` | `1s`, `2s` | A command that times out closes its connection, which reopens on the next one |
| `REDIS_MAX_IN_FLIGHT` | `1024` | Commands waiting for replies on one connection; more are refused at once |
| `QUEUE_REDIS_NAMESPACE` | `daravel` | The queues' key space, apart from Laravel's `queues:` |

`/up/ready` gains a `redis` check (`PING`). Passwords never appear in logs or
errors.

## The `Redis` facade

```dart
await Redis.set('greeting', 'halo', ttl: const Duration(minutes: 5));
final greeting = await Redis.get('greeting');
await Redis.command(['HSET', 'user:7', 'name', 'Ana']);

final script = RedisScript("return redis.call('INCRBY', KEYS[1], ARGV[1])");
await Redis.eval(script, keys: ['visits'], args: [1]);

await Redis.publish('orders', '{"id":7}');
Redis.subscribe(['orders']).messages.listen((message) { /* ... */ });
```

Each isolate keeps one connection, and commands sent without awaiting each
other share its round trips (pipelining). Blocking commands and
subscriptions get connections of their own; a subscription subscribes again
after the connection drops.

## Guarantees

- **Cache reads fail open:** with Redis down, a read is a miss and the
  application answers from the source. Writes throw.
- **Locks fail closed** and belong to their owner, as Laravel's
  `RedisLock`. They are single-instance locks, not Redlock: a failover with
  asynchronous replication can lose one. For work that must never run twice
  (billing), lock in the database.
- **Jobs run at least once:** a job reserved by a worker that died runs
  again after `QUEUE_RETRY_AFTER`. Handlers should be idempotent, as in
  Laravel. A job's payload stays exactly what was pushed.
- **Pub/Sub is at most once:** an event published while a server
  reconnects does not reach that server's clients.

## With Laravel on the same Redis

| | |
| :-- | :-- |
| Locks | Shared once both use the same `REDIS_PREFIX` and `CACHE_PREFIX`: the same keys on the same connection, `SET NX PX` and the same release script. `dartisan adopt` gives Daravel a cache prefix of its own, so set `CACHE_PREFIX` to Laravel's to share them |
| Numbers in the cache | Shared: stored as plain digits |
| Other cache values | Daravel stores JSON, Laravel PHP's `serialize()`: neither reads the other's |
| Queues | Kept apart (`daravel:` namespace): Laravel's workers cannot run Daravel jobs, nor the other way round |

`bench/interop/redis.sh` checks this against Laravel 12 with predis: a lock
taken by either is refused to the other with the same owner, and a cached
number counts up from both sides.

## Not yet

Redis Sentinel and Cluster, a two-level cache with `CLIENT TRACKING`, the
Streams queue engine and a PHP-compatible serializer are planned. Until
then, point `REDIS_URL` at a single primary (a managed service's endpoint
works).
