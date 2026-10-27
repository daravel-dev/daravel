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

It works with Redis 6.2 or newer and with Valkey, on one server, behind
Sentinel or as a Redis Cluster, and speaks the protocol itself (no native
library).

## Installing

```bash
dartisan redis:install --docker   # or: dart pub add daravel_redis
```

`redis:install` adds the package, `.withRedis()` and the `redis:*` commands,
the `.env` keys in `.env.example` and, with `--docker`, a Valkey service in
the compose file (`--server=redis` for Redis).

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
| `CACHE_STORE=tiered` | The same, with each isolate's memory in front of Redis ([below](#a-cache-in-each-isolate)) |
| `CACHE_LIMITER=redis` | Each attempt is one Lua script; blocked attempts are not counted |
| `QUEUE_CONNECTION=redis` | Jobs in Redis; an idle worker blocks on `BLPOP` and starts a pushed job at once instead of after `--sleep`. Unique-job locks and `queue:restart` / `queue:pause` go to Redis as well (`QUEUE_UNIQUE_LOCK_STORE=redis`) |
| `REVERB_SCALING_DRIVER=redis` | Frames between servers over Pub/Sub; presence members, the channels API and cache channels in Redis ([Broadcasting](broadcasting.md#several-servers)) |

The cache uses the `cache` connection (`REDIS_CACHE_DB`, 1 by default), so
`dartisan cache:clear` deletes only the cache's keys (`SCAN` and `UNLINK`
on its prefix, never `FLUSHDB`) and never queued jobs.

## Configuration

| Variable | Default | Purpose |
| :-- | :-- | :-- |
| `REDIS_URL` | none | `redis://` or `rediss://` (TLS), `user:password@host:port/database`; `redis+sentinel://` and `redis+cluster://` list several hosts ([below](#sentinel-and-cluster)). Replaces the variables below |
| `REDIS_HOST`, `REDIS_PORT` | `127.0.0.1`, `6379` | The server |
| `REDIS_USERNAME`, `REDIS_PASSWORD` | none | ACL user (Redis 6+) and password |
| `REDIS_DB`, `REDIS_CACHE_DB` | `0`, `1` | Databases of the `default` and `cache` connections, as in Laravel |
| `REDIS_PREFIX` | `<app>-database-` | Put before every key, Laravel 12's default |
| `REDIS_CACHE_LOCK_CONNECTION` | `default` | Where cache locks live, as Laravel's `lock_connection` |
| `REDIS_TLS` | `false` | TLS without `rediss://`; boot warns when a public host goes without it |
| `REDIS_COMMAND_TIMEOUT`, `REDIS_CONNECT_TIMEOUT` | `1s`, `2s` | A command that times out closes its connection, which reopens on the next one |
| `REDIS_MAX_IN_FLIGHT` | `1024` | Commands waiting for replies on one connection; more are refused at once |
| `REDIS_MODE` | `standalone` | `sentinel` or `cluster`, with `REDIS_NODES` |
| `REDIS_NODES` | `REDIS_HOST:REDIS_PORT` | `host:port,host:port`: the Sentinels, or the cluster nodes to start from |
| `REDIS_SENTINEL_SERVICE` | `mymaster` | The master's name at the Sentinels |
| `REDIS_SENTINEL_USERNAME`, `REDIS_SENTINEL_PASSWORD` | none | The Sentinels' own credentials |
| `REDIS_SERIALIZER` | `json` | `php` writes cached values as Laravel's `serialize()`; both are always read |
| `REDIS_TIERED_MAX_KEYS`, `REDIS_TIERED_TTL` | `10000`, `60s` | The `tiered` store's entries per isolate and their longest life |
| `QUEUE_REDIS_ENGINE` | `list` | `stream` keeps jobs in a stream with a consumer group |
| `QUEUE_REDIS_NAMESPACE` | `daravel` | The queues' key space, apart from Laravel's `queues:` |

`/up/ready` gains a `redis` check (`PING`). Passwords never appear in logs or
errors.

## Sentinel and Cluster

```dotenv
# The master Sentinel names, found again after a failover
REDIS_URL=redis+sentinel://:secret@10.0.0.21:26379,10.0.0.22:26379/mymaster/0

# A Redis Cluster, from any of its nodes
REDIS_URL=redis+cluster://:secret@10.0.0.31:6379,10.0.0.32:6379
```

With Sentinel, each connection asks the Sentinels for the master and checks
its `ROLE`. After a failover the old master drops its clients, which
reconnect to the new one; a write refused by a demoted master (`READONLY`)
did not run and is sent again to the new master. Writes accepted by the old
master in the moment before Sentinel demotes it can be lost: that window
belongs to Redis's asynchronous replication.

In a cluster, each command goes to the master of its key's hash slot, from
a slot map read with `CLUSTER SLOTS` and corrected by `MOVED` and `ASK`
while slots move. `MGET`, `DEL`, `UNLINK`, `EXISTS` and `TOUCH` over keys of
several slots are split per slot; `SCAN` (and so `cache:clear`) visits
every master. Everything Daravel runs as one script shares a hash tag
(`{default}` for a queue), so it stays on one slot; your own scripts over
several keys need one too (`{user:7}:a`, `{user:7}:b`), or the server
answers `CROSSSLOT`. A cluster has only database 0, so `REDIS_CACHE_DB`
does not apply there.

## A cache in each isolate

`CACHE_STORE=tiered` keeps what each isolate reads in its own memory (L1)
in front of Redis (L2), and Redis tells every server when one of those keys
is written (`CLIENT TRACKING` in broadcast mode, RESP3). A read from L1 is
then never older than the last write the server was told of; only the
short trip of that notice separates them.

```dart
final user = await Cache.store('tiered').remember('user:7', null, loadUser);
```

Its values live under a prefix of their own (`tiered:`), so only they are
broadcast; locks and rate limits go to the `redis` store as usual. Until
tracking is running, and on servers without it, every read goes to Redis.
An entry lives at most `REDIS_TIERED_TTL` and follows the key's own time to
live; at most `REDIS_TIERED_MAX_KEYS` stay, the least recently read leaving
first.

## Cache tags

```dart
await Cache.tags(['people', 'artists']).put('John', john, ttl: const Duration(hours: 1));
await Cache.tags(['people']).flush();
```

Tagged entries are laid out as Laravel 12 lays them out on Redis: the value
under `<cache prefix><sha1 of the tags>:<key>`, and each tag's keys in a
sorted set `<cache prefix>tag:<name>:entries`, scored by when they expire. A
flush deletes the keys its tags list, so either framework flushes what the
other tagged. Expired keys stay in the lists until
`dartisan cache:prune-stale-tags` (Laravel's command of the same name,
worth scheduling) drops them. The `tiered` store tags too, with tag ids as
Laravel's array store.

## Queue engines

`QUEUE_REDIS_ENGINE=list` (the default) keeps jobs in lists and sorted sets.
`stream` keeps them in a Redis stream read by a consumer group: the server
itself tracks the jobs being run (`XPENDING`), and a job whose worker died
is claimed by another after `QUEUE_RETRY_AFTER` (`XAUTOCLAIM`, by the
server's clock). Both wake idle workers the same way, and the payload stays
byte for byte what was pushed. Switch engines with an empty queue: each
keeps its jobs under keys of its own.

## Rate limit algorithms

Laravel's fixed window lets up to twice the limit through around a reset.
With `CACHE_LIMITER=redis`, two other algorithms are one script each, on
the Redis server's clock:

```dart
limiter.define('login', (request) => Limit.perMinute(5).by(request.ip).gcra());
limiter.define('search', (request) => Limit.perMinute(60).slidingWindow());
```

| Algorithm | Counts |
| :-- | :-- |
| `fixedWindow` (default) | Laravel's: hits since the window's first hit |
| `slidingWindow()` | The current window plus the previous one, weighted by how much of it is still within the decay |
| `gcra()` | One attempt every decay / limit, the whole limit as a burst after a quiet period |

`Retry-After` says when the next attempt passes under each.

## Events that resume

```dart
router.get('/orders/events', (request) =>
    Response.sse(Redis.events('orders').since(request)));

await Redis.events('orders').publish({'id': 7}, event: 'created');
```

Each event goes into a stream (`<REDIS_PREFIX>sse:orders`, about the last
1000 kept) and its stream id is the event's `id:`. A browser that
reconnects sends `Last-Event-ID`; it first gets what it missed, then the
live events, none twice and none lost in between. Every listener of a
channel in an isolate shares one `XREAD BLOCK` connection.

## The `Redis` facade

```dart
await Redis.set('greeting', 'halo', ttl: const Duration(minutes: 5));
final greeting = await Redis.get('greeting');
await Redis.command(['HSET', 'user:7', 'name', 'Ana']);
final [name, ttl] = await Redis.connection().pipeline([
  ['HGET', 'user:7', 'name'],
  ['TTL', 'user:7'],
]);

final script = RedisScript("return redis.call('INCRBY', KEYS[1], ARGV[1])");
await Redis.eval(script, keys: ['visits'], args: [1]);

await Redis.publish('orders', '{"id":7}');
Redis.subscribe(['orders']).messages.listen((message) { /* ... */ });
```

`publish(..., sharded: true)` and `subscribe([...], sharded: true)` use
sharded Pub/Sub (Redis 7): in a cluster a message stays within its channel's
shard, and a subscription follows the shard when its slot moves. Sharded
channels must share a hash slot (`{orders}:created`, `{orders}:paid`).

```dart
// At most 10 per minute, counted with Laravel's Redis::throttle('reports')
await Redis.throttle('reports').allow(10).every(const Duration(minutes: 1))
    .then(() => sendReport(), (error) => releaseLater());

// At most 3 at a time (Laravel's Redis::funnel)
await Redis.funnel('imports').limit(3).block(const Duration(seconds: 5))
    .then(() => runImport());
```

`throttle` and `funnel` use Laravel's scripts and keys (with
`REDIS_PREFIX`), so both frameworks count against one limit. As in Laravel,
a `throttle` window runs from a whole second to that second plus the
period. A `funnel` in a cluster needs a hash tag in its name
(`{imports}`), since its slots are keys of their own.

Each isolate keeps one connection per server, and commands sent without
awaiting each other share its round trips (pipelining). Blocking commands
and subscriptions get connections of their own; a subscription subscribes
again after the connection drops.

## Commands

```dart
// bootstrap/commands.dart
import 'package:daravel_redis/commands.dart';

final List<CommandFactory> commands = [...redisCommands];
```

They come from a library of their own, so the server does not compile the
CLI.

| Command | What it does |
| :-- | :-- |
| `redis:ping [--connection]` | The server, its version, the mode and the round trip |
| `redis:stats [--connection]` | Each master's `INFO` (memory, clients, hits) and what the client did (connections, redirections, failovers) |
| `redis:keys-audit [--connection] [--match] [--limit]` | Keys by type under `REDIS_PREFIX`, and the cache keys that never expire |
| `redis:cli [--connection] [--write] [command ...]` | One command, or a prompt; only reading commands run without `--write` (`KEYS` neither: use `SCAN`) |
| `redis:inspect <key> [--connection]` | What a key holds: type, time to live, encoding, size, memory and its first items (values hidden in production). Also the MCP tool `redis_inspect` ([dartisan](dartisan.md#ai-coding-agents-mcp)) |
| `cache:prune-stale-tags [--store]` | Drops expired keys from the tag lists |

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
| Other cache values | Shared with `REDIS_SERIALIZER=php`: Daravel writes PHP's `serialize()` for strings, booleans, lists and maps, and reads Laravel's values, objects as maps of their properties. With `json`, Laravel cannot read Daravel's values |
| Tags | Shared: the same keys and tag lists; a flush from either reaches what the other tagged |
| `Redis.throttle`, `Redis.funnel` | Shared with `Redis::throttle` and `Redis::funnel` of the same name: Laravel's scripts and keys |
| Queues | Kept apart (`daravel:` namespace): Laravel's workers cannot run Daravel jobs, nor the other way round |

`bench/interop/redis.sh` checks this against Laravel 12 with predis: a lock
taken by either is refused to the other with the same owner, a cached
number counts up from both sides, each reads the other's cached arrays and
tagged entries and flushes the other's tags, and one throttle counts both.

## Not yet

`REDIS_TOPOLOGY=coordinator`, which would route every isolate's commands
through one set of connections per server for managed services with a low
connection limit, is planned. Until then each isolate opens its own.
