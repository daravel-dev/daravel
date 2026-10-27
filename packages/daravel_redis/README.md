<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_redis

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_redis/README.id.md)

Redis and Valkey for [Daravel](https://pub.dev/packages/daravel) on several
servers: a shared cache and locks, rate limits in one round trip, queues
that start a job as soon as it is pushed, and broadcasting between servers.
On one server Daravel needs none of it; its coordinator keeps that state in
memory.

```bash
dart pub add daravel_redis
```

```dart
// bootstrap/app.dart
import 'package:daravel_redis/daravel_redis.dart';

Application createApp() => Application.configure(basePath: '.')
    .withRedis()
    // ...
    .create();
```

```dotenv
REDIS_HOST=127.0.0.1       # or REDIS_URL=rediss://user:secret@host:6380/0
REDIS_PASSWORD=
CACHE_STORE=redis          # cache, locks, the JWT denylist
CACHE_LIMITER=redis        # rate limits
QUEUE_CONNECTION=redis     # jobs without polling (BLPOP)
REVERB_SCALING_ENABLED=true
REVERB_SCALING_DRIVER=redis
```

- Speaks RESP itself, with pipelining on one connection per isolate,
  command timeouts, bounded in-flight commands and TLS. Tested on Redis 7
  and Valkey 8.
- Locks are Laravel's `RedisLock` (keys, connection, release script), so
  Laravel and Daravel share them with the same `CACHE_PREFIX`.
  Queues stay apart from Laravel's (`daravel:` keys).
- `cache:clear` deletes the cache's own keys, never the whole database.

Documentation: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/redis.md>.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC; Redis is a trademark of Redis Ltd.; Valkey is a
project of the Linux Foundation. Daravel is an independent project, not
affiliated with or endorsed by any of them.
