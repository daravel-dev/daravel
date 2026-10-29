# Operations

Running Daravel under real traffic: how many isolates, how many database
connections, when to refuse work, what to watch and how to stop. The
mechanics are in [Deployment](deployment.md); this page is about the
numbers. Measure on your own hardware before settling on any of them
([Benchmarks](benchmarks.md) shows how).

## Isolates

`APP_ISOLATES=N` runs a supervisor and N worker isolates on one port. Each
worker has its own event loop, so a worker uses at most one core; one
isolate leaves the other cores idle.

- Start with one isolate per core (or vCPU) the server may use, and measure.
  `dartisan doctor` notes `APP_ISOLATES=1: you are using 1 of N cores`.
- On a container platform the number of cores is the container's CPU
  limit, not the host's: two vCPUs means `APP_ISOLATES=2`.
- More isolates than cores adds context switches, not throughput.
- Endpoints that allocate a lot per request (a thousand wide rows decoded
  and encoded as JSON) scale poorly across the isolates of one process:
  measured, four isolates gained almost nothing while four processes
  gained 2.6×, most likely because the isolates share one heap and its
  garbage collections pause them all.
  Paginate such endpoints, stream them a page at a time
  (`Response.streamJson`, [Responses](responses.md#streaming-a-large-json-array)),
  or run several server processes behind the
  proxy instead of more isolates: `APP_PROCESSES=N`
  ([Deployment](deployment.md#several-processes)); benchmark scenario 13
  measures it (`bench/README.md`).
- Each isolate has its own memory, so state an application keeps in a
  static (a revoked-token list, a counter, a cached value) exists once per
  isolate. Keep it in a shared store before raising `APP_ISOLATES`:
  `RateLimiter` for limits and counters, `Cache.store('process')` for
  short-lived values on one machine, the `database` or Redis cache store
  for what must survive a restart or reach every server (the `process`
  store keeps `CACHE_PROCESS_MAX_ENTRIES` entries, 10 000 by default, and
  starts empty), and
  `Auth.jwtGuard().invalidate()` for JWTs. `dartisan lint` reports such
  statics (`no_mutable_static_in_app`).
- Process-wide state (rate limits, the `process` cache store, locks,
  metrics) goes through the coordinator in the supervisor isolate, so a
  limit such as `throttle:60,1` holds for the whole server, not per
  worker.

## Database connections

Every isolate opens its own pool of `DB_POOL_SIZE` connections (10 by
default, or `pool=` in `DB_URL`), so a deployment opens up to:

```text
instances × APP_PROCESSES × (APP_ISOLATES + embedded workers) × DB_POOL_SIZE
```

connections (the embedded queue worker and scheduler, `SERVER_EMBED_QUEUE`
/ `SERVER_EMBED_SCHEDULER`, are isolates with a pool of their own), plus
separate queue workers, the scheduler, migrations and any Laravel
application on the same database. Keep that under about 80% of the
server's `max_connections` (100 by default on PostgreSQL, 151 on MySQL and
MariaDB). `dartisan doctor` computes one instance's product for
PostgreSQL, MySQL and MariaDB, compares it with the server's
`max_connections` and warns above 80%.

When the product is too large, lower `DB_POOL_SIZE` first: a worker rarely
needs more connections than it has requests waiting on the database at
once. If you run many instances, put a connection pooler such as PgBouncer
between them and PostgreSQL.

SQLite is a file, not a server: it has no connection limit, and it is the
wrong choice for production with several isolates (see
[Database](database.md#sqlite-or-postgresql)).

## Load shedding

Without a limit an overloaded worker queues every request until all of them
time out together. Two per-worker limits refuse the excess with `503` and
`Retry-After: 1` instead ([Load shedding](deployment.md#load-shedding)):

- `HTTP_MAX_QUEUE_DELAY` (new projects set `200ms`) refuses while the
  worker's event loop runs that late. It is the limit that sees CPU-bound
  or SQLite work, which the in-flight limit cannot; set it to the queueing
  delay you are willing to add to a response, and measure.
- `HTTP_MAX_IN_FLIGHT` caps requests awaiting I/O at once; about 2–4×
  `DB_POOL_SIZE` for a worker doing database work.

A steady stream of refusals (`http_requests_shed_total`) means the server
needs more isolates or instances, not a higher limit.

## Behind a reverse proxy

The workers share the port, and the operating system hands each new
*connection* to one of them; requests on that connection stay with that
worker. A proxy that keeps a single long-lived connection to the server
therefore sends everything to one worker. Let the proxy keep a pool of
upstream connections, several per worker. With nginx:

```nginx
upstream daravel {
    server 127.0.0.1:8000;
    keepalive 64;
}

server {
    location / {
        proxy_pass http://daravel;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
    }
}
```

`http_requests_in_flight{worker="..."}` shows whether the workers are
evenly loaded.

## What to watch

Enable `/metrics` (`METRICS_ENABLED=true`, with `METRICS_TOKEN` in
production) and scrape it with Prometheus. Under a supervisor the numbers
of every worker are merged.

| Metric | Watch for |
| :-- | :-- |
| `http_request_duration_seconds` | p99 per route (`histogram_quantile(0.99, ...)`): the latency users feel |
| `http_requests_shed_total{worker}` | any steady rate: the server is overloaded |
| `http_requests_in_flight{worker}` | one worker much busier than the others: connection distribution (see above) |
| `http_requests_total{status}` | the share of `5xx` |
| `process_resident_memory_bytes` | steady growth over hours or days |
| `coordinator_messages_total` | its rate (`rate(...[1m])`) climbing with traffic: every worker asks the coordinator, which answers on the supervisor's event loop |
| `coordinator_call_duration_seconds{service}` | p99 above about 2 ms: rate limits, process cache reads and locks wait for the coordinator |
| `coordinator_rejected_total`, `coordinator_in_flight_peak` against `coordinator_max_queue` | any refusal, or a peak near the limit |
| `coordinator_call_timeouts_total{service}` | any steady rate |

`dartisan coordinator:stats --url=http://127.0.0.1:8000/metrics` reads
these from a running server and says what to do: back the rate limiter
with the cache store (`CACHE_LIMITER=database`), keep hot process cache
keys in each worker for a moment (`CACHE_PROCESS_L1_TTL=1s`), or move
that state to Redis (`withRedis()`).

Database connections are best watched on the database side
(`pg_stat_activity` on PostgreSQL), against the formula above.

## Graceful shutdown

On `SIGTERM` (or `SIGINT`) the server stops accepting connections, `/up`
answers `503` so a load balancer stops sending traffic, open WebSockets are
closed with "going away" so clients reconnect elsewhere, and in-flight
requests finish within `SHUTDOWN_TIMEOUT` (30 s by default). Under a
supervisor every worker drains, and a worker still running two seconds
after that is killed.

Give the orchestrator's grace period more than `SHUTDOWN_TIMEOUT`: Cloud
Run kills a container 10 s after `SIGTERM`, so use `SHUTDOWN_TIMEOUT=8s`
there; with systemd, keep `TimeoutStopSec` above it.
