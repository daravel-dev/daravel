# Daravel benchmark harness

Implements BLUEPRINT_V2 §10.2. Numbers are measured, never claimed (P10):
the harness builds the servers AOT, runs them on loopback and reports
throughput and latency for each scenario.

```bash
cd bench
dart run bin/bench.dart                              # isolates 1 and 4, 10 s per scenario
dart run bin/bench.dart --duration=5 --isolates=1,4,8 --out=results.json
dart run bin/bench.dart --scenarios=1,5 --skip-build # only ping and throttle
dart run bin/bench.dart --compare=baseline.json      # exit 1 on a > 10% regression
```

Options: `--connections=64`, `--client-isolates=N` (load generator isolates,
default half the CPUs), `--threshold=0.10`.

## What runs

| Id | Scenario | Endpoint |
| :-- | :-- | :-- |
| 0 | plain `dart:io` reference | `GET /ping` on `bin/baseline.dart` |
| 1 | framework overhead | `GET /ping` (text) |
| 2 | JSON + one query | `GET /api/users/42` |
| 3 | validation + insert in a transaction | `POST /api/users` |
| 4 | eager loading (no N+1) | `GET /api/posts` with `author`, `comments` |
| 5 | rate limiter (coordinator) | `GET /api/throttled` |
| 6 | login (bcrypt cost 10 in the compute pool) | `POST /api/login` |
| 9 | Zone scope and facade microbenchmark | `server --micro` |
| 10 | startup to first `/up` and idle RSS | every isolate count |
| 11 | overload: scenario 2 under `--overload-connections` (512) against three servers: no limit, `HTTP_MAX_IN_FLIGHT=--max-in-flight` (32), and `HTTP_MAX_QUEUE_DELAY=--max-queue-delay` (50 ms) added | `GET /api/users/42` |
| 12 | open loop: the capacity of scenario 2 is measured, then `--open-loop-factor` (1.5) times it is offered at a fixed rate to the same three servers, with up to `--overload-connections` | `GET /api/users/42` |
| 13 | large result set: 1 000 rows of a 40-column table (`wide_rows`), decoded and encoded as JSON per request (`?php=1` adds the `json_encode` rewrite) | `GET /api/wide` |

Scenarios 7 (5 MB multipart) and 8 (1 000 idle SSE connections) wait for
multipart and SSE support (Tier 2).

Scenario 11 reports goodput (successful requests per second), latency
percentiles of the successful requests, and `shed`, the share of attempts
refused with 503. The generator ignores `Retry-After` and reconnects at
once, the worst case for the server. Expect the in-flight limit alone to
change little: scenario 2's handler is synchronous SQLite work that finishes
inside one event-loop turn, so the queue forms before the engine sees it;
the queue-delay limit is the one that sees that queue (see
`docs/guide/deployment.md#load-shedding`). `--scenarios` ids match
exactly (`--scenarios=1` does not select 11).

Scenario 11 is a closed loop: each client sends its next request as soon as
one is answered, refusals included, so the number of waiting requests never
falls and shedding can only add the cost of its refusals. Scenario 12 is the
open loop that load shedding is for: requests arrive at a fixed rate,
whatever the server does, as from many independent users, and a refused
request is not retried. Its latency is counted from when each request was
due, so time spent waiting for a connection or behind a slow server counts
(no coordinated omission). The `open_loop_isolates_N` target compares p99
and goodput of the limited servers with the unlimited one.

The database is SQLite (`build/bench.sqlite`, seeded with 1 000 users,
200 posts, 2 000 comments), or PostgreSQL, seeded the same way:

```bash
dart run bin/bench.dart --database='pgsql://user:secret@127.0.0.1:5432/bench?pool=4' 
  --scenarios=2,3,4,11 --isolates=1,4
```

`--database` takes a SQLite path or a `pgsql://`, `postgres://`,
`postgresql://`, `mysql://` or `mariadb://` URL (`--db-url` is the same).
Scenarios 2–4, 11 and 13 are the ones that query. When nothing answers at
that address the harness prints
`database scenarios skipped: nothing answers at host:port` and exits 0, so
the nightly workflow, which runs these four against a PostgreSQL service
container, does not fail when the database is missing.

## Reading the results

Absolute requests per second depend on the machine, and the load generator
shares it with the server. Each scenario is therefore also reported as
`relative_to_dartio`: its throughput divided by the plain `dart:io` server
measured in the same run with the same isolate count. `--compare` gates on
that ratio, which is what the nightly workflow (`.github/workflows/bench.yml`)
uses. To set the baseline, copy a nightly `results.json` artifact to
`bench/baseline.json` and commit it.

Internal targets (§10.2, not public promises) are printed at the end:
ping overhead ≤ 25% against `dart:io`, throttling adds ≤ 100 µs of service
time per request (measured as `1/rps` on one isolate, since latency percentiles
under concurrent load are mostly queueing), and four
isolates give ≥ 3× the ping throughput of one on a 4+ core machine.

### Sending values between isolates

`bin/isolate_payload.dart` measures the round trip of one JSON document
to another isolate and back as a `Map`, a `String`, a `Uint8List` and a
`TransferableTypedData`, and of the same rows as a `List` of objects of a
plain final class and of a `@pragma('vm:deeply-immutable')` class (an
immutable class graph). Measured on 2026-11-05 (Dart 3.13.4 AOT, Windows
x64; the two object rows are the range of three runs of
`dart build cli -t bin/isolate_payload.dart`):

| Payload | 1 KB | 85 KB | 888 KB |
| :-- | --: | --: | --: |
| `Map<String, Object?>` (copied by the sender) | 18 µs | 480 µs | 9 000 µs |
| `String` (shared between the isolates of a process) | 4 µs | 5 µs | 6 µs |
| `Uint8List` (copied) | 5 µs | 30 µs | 900 µs |
| `TransferableTypedData` (moved, then materialized) | 9 µs | 50 µs | 250 µs |
| `List` of plain objects (copied) | 5–6 µs | 108–113 µs | 1 420–1 870 µs |
| `List` of deeply-immutable objects (shared; only the list is copied) | 4–6 µs | 10–12 µs | 62–72 µs |

The `process` cache store sends values as JSON strings because of this
(ADR-031); `TransferableTypedData` pays off only for large binary data.
Typed coordinator messages are deeply-immutable classes
(`CoordinatorMessage`, ADR-032), so a batch of them is not copied either.

### Scenario 13 and isolates

`bin/wide_profile.dart` splits scenario 13 into query, row decoding and
JSON encoding without HTTP. Measured on 2026-10-29 (Dart 3.13.4 AOT,
Linux container, 16 vCPU, MariaDB 12.3 on the same Docker network, pool 4):

| Run | Full query of 1 000 × 40 rows |
| :-- | --: |
| one isolate | 19 ms (`id` only: 1.7 ms; JSON encoding: 8 ms more) |
| four queries at once in one isolate | 89 ms |
| four isolates of one process in parallel | 81–90 ms each |
| four processes in parallel | 28 ms each |

Decoding a large result is CPU and allocation work in the isolate, and it
does not scale across the isolates of one process, while separate
processes do. The likely cause is that the worker isolates of one process
share a heap (an isolate group), so a garbage collection pauses all of
them; the run above logged 283 collections. A larger new generation helps a little
(`DART_VM_OPTIONS=--new_gen_semi_max_size=128`: 70–77 ms each). Run from
Windows against a database in WSL, the port relay adds about 80 ms per
query, so measure on Linux.

Most of the one-isolate time was Daravel's own row conversion, not
`mysql_dart`: `MySqlDriver.select` built three 40-entry maps per row and
parsed every DATETIME into a `DateTime` it then discarded. Reading each row
in one pass (daravel_mysql, unreleased) brought the driver-level time of
the full query from 21 ms to 10 ms (p50, same setup); `mysql_dart` itself
takes about 10 ms for the 788 KB result, of which UTF-8 decoding of the
40 000 fields is about 4.5 ms, and `package:postgres` takes about 33 ms
for the same rows.

`--processes=N` runs the Daravel server as N processes on consecutive ports
(`APP_PROCESSES`, ADR-027) and spreads the client isolates over them, for
endpoints that do not scale across isolates. On Windows with SQLite, one
isolate and 16 connections, scenario 13 went from 28 req/s with one process
to 46 req/s with two (2026-10-29):

```bash
dart run bin/bench.dart --scenarios=13 --isolates=1 --processes=2
```

## Interop with Laravel's broadcasting

`bench/interop/run.sh` (Linux and Docker) runs `laravel-echo` and
`pusher-js` from npm against Daravel's Pusher protocol server, Laravel 12
broadcasting through Daravel, Daravel broadcasting through Laravel Reverb,
and Echo on one of two Daravel servers that share a database
(`REVERB_SCALING_ENABLED`); `ISOLATES=4` runs Daravel with four worker
isolates. It is a compatibility check, not a benchmark.

`bench/interop/redis.sh` puts Laravel 12 (predis) and Daravel
(`daravel_redis`) on one Redis: a cache lock taken by either is refused to
the other, with the same owner, and a cached number counts up from both.

`bench/interop/permission.sh` runs Laravel 12 with spatie/laravel-permission
6 and Daravel (`daravel_permission`) on one SQLite database: Spatie's own
migration creates the tables, and roles given by either are seen by the
other.

`bench/interop/connections.sh` is the capacity test: it builds the interop
server AOT, opens `COUNT` (10 000) idle Pusher connections with
`bin/connections.dart`, all on one channel, and prints the server's RSS
idle and loaded and the time one event takes to reach every connection
(`ISOLATES=4` for four worker isolates). The client connects from
127.0.0.2 onwards, since one source address has only a few thousand local
ports on some systems (WSL). Results are in
[Broadcasting](../docs/guide/broadcasting.md#capacity).

## Against Laravel

`bench/laravel/compare.sh` (Linux and Docker) runs the same scenarios
against Laravel 12 on PHP 8.4 with OPcache, from `bench/laravel/Dockerfile`:

```bash
bash bench/laravel/compare.sh                       # 10 s per scenario, 4 workers
DURATION=20 WORKERS=8 SERVER_CPUS=0-7 CLIENT_CPUS=8-15 bash bench/laravel/compare.sh
```

- **Daravel**: the AOT build, with 1 and `WORKERS` isolates.
- **Laravel Octane** on FrankenPHP's worker mode (the application stays in
  memory between requests), with 1 and `WORKERS` workers.
- **Laravel classic**: FrankenPHP without worker mode, which boots the
  application for every request, as php-fpm does.

The endpoints in `bench/laravel/overlay/` do what `lib/bench_app.dart`
does: the same routes, validation rules, queries and responses. Both use
one SQLite database, seeded by Daravel (Laravel reads its `$2y$` hashes as
they are), with the same settings (WAL, `busy_timeout` 5000,
`synchronous=NORMAL`). Laravel's configuration and routes are cached, as in
production. Every server runs on `SERVER_CPUS` and the load generator on
`CLIENT_CPUS`, so they never compete for a core.

Two differences favour Laravel: its rate limiter uses the `array` cache, so
each Octane worker counts on its own, where Daravel's limit is shared by
every isolate through the coordinator; and `/ping` is registered outside the
`web` middleware group (no session or CSRF), as Daravel's is.

`bench.dart --external=name:port` measures any server that is already
running, and `bin/laravel_report.dart <dir>` prints the table.
`CONNECTIONS=16,64,256` measures every scenario at each connection count,
and `WORKER_COUNTS=4` skips the one-worker runs. `DB=pgsql` starts a fresh
PostgreSQL container (`PG_IMAGE`, default `postgres:17`, port 18632, on the
servers' cores) and points both sides at it through `DB_URL`: Daravel with a
pool of 4 connections per isolate, Laravel with one connection per Octane
worker, or one per request in classic mode.

Laravel's settings (`APP_KEY`, the cache and session stores, the log
channel) are passed by `compare.sh` as environment variables, not read
from an `.env` in the overlay: that file is git-ignored, so a fresh clone
or worktree had none and Octane stopped on boot (`MissingAppKeyException`).
The key is the benchmark's throwaway one, the same 32 bytes as Daravel's.
`compare.sh` stops with the server's log when Laravel never answers `/up`.


## The coordinator: ceiling, census and saturation (Blueprint #141, K0)

Measured on 2026-11-10 on one machine: Intel i7-10875H (8 cores, 16
threads) under WSL 2 (Linux 6.18.58), Docker, servers pinned to cores 0-3
and the load generators to 4-11. Daravel 1.27 from this branch, AOT, Dart
3.13.7 (the `dart:stable` image of that day; the repository pins 3.13.4 in
`.fvmrc`); Laravel 12.71.0, Octane 2.23.0 on FrankenPHP 1.13.3, PHP 8.4.27
with OPcache, Sanctum 4.3.3; PostgreSQL 17.11, Redis 7.4.10. One machine,
loopback, three scenarios: these are not general claims.

### Daravel and Laravel, with the coordinator in the path

Scenario 14 (`token + rate limit + cache`): a Sanctum-style bearer token,
a rate limit, and a cached read. `CACHE_VARIANT=redis` puts the cache and
the limiter of both sides on one Redis; `DB=pgsql` puts both on one
PostgreSQL. Median of three runs, each started with a 1-minute load under
2 (1.89 to 1.95), errors 0 throughout, with the lowest and highest run:

| 4 workers, `pgsql` + `redis` | Daravel | Octane | classic | Daravel ÷ Octane |
| :-- | --: | --: | --: | --: |
| `GET /ping` | 11 005 req/s [10 498–11 401], p99 13.7 ms | 1 948 [1 835–1 998], p99 44.8 ms | 784 [783–784], p99 115.7 ms | 5.6× |
| rate limited | 7 424 [7 362–7 480], p99 18.2 ms | 763 [714–769], p99 98.9 ms | 510 [506–511], p99 154.6 ms | 9.7× |
| token + rate limit + cache | 2 078 [1 959–2 119], p99 49.8 ms | 377 [370–383], p99 192.9 ms | 174 [170–176], p99 420.5 ms | 5.5× |

With one worker: 5 596 vs 738 req/s (7.6×), 4 578 vs 251 (18.2×) and
1 091 vs 127 (8.6×).

- **`last_used_at`.** Sanctum writes `personal_access_tokens.last_used_at` on
  every authenticated request (`config('sanctum.last_used_at', true)`);
  Daravel writes it at most once a minute per token. That is a difference
  in behaviour. With `SANCTUM_LAST_USED_AT=false` Laravel barely changes
  (Octane 372 req/s, classic 168), so the write is not what limits it here.
  In that variant two cells spread more than 10 % over the three runs:
  Octane's token scenario with one worker (17.7 %) and Daravel's rate
  limited route with one worker (17.7 %).
- **SQLite against PostgreSQL.** On SQLite (`CACHE_VARIANT=redis`, three
  runs) Daravel's scenario 14 reaches 4 009 req/s with 4 isolates (Octane
  523); on PostgreSQL it is 2 078. The difference is the token query to
  PostgreSQL, with a pool of 4 connections per isolate (`PG_POOL`); ping
  and the rate limit barely change. It is not a regression.
- **Runs left out.** Two SQLite runs fell about 4× on both sides at once
  while the Windows host compiled and generated docs (the VM shares its
  cores) and were redone; the `process` cache variant is still being redone
  for the same reason, so it is not quoted here.

### Coordinator messages per request (census)

`bin/coordinator_census.dart` reads the coordinator's message counters
(`coordinator_call_duration_seconds_count`) before and after 20 000
requests on 4 isolates; identical in three runs:

| Scenario | Messages per request |
| :-- | --: |
| `GET /ping`-like JSON route (2) | 0 |
| rate limited (5) | 0.063 (rate limiter leases) |
| token + rate limit + `process` cache (14) | 1.063 (1.0 the cache read) |
| the same with a JWT guard | 2.06 (1.0 more for the denylist) |
| metrics | 0.0015 |

### The coordinator's ceiling

`bin/coordinator_ceiling.dart` (AOT, `dart build cli`) drives one
coordinator from 1, 4, 8 and 16 client isolates, 16 calls in flight each,
5 s per point. Median of three runs, thousands of operations per second:

| Operation | 1 | 4 | 8 | 16 |
| :-- | --: | --: | --: | --: |
| rate limit attempt (no lease) | 184 | 90 | 47 | 34 |
| `process` cache get | 168 | 88 | 43 | 31 |
| broadcast publish | 171 | 101 | 50 | 39 |
| a service that does nothing (`noop`) | 224 | 99 | 56 | 43 |
| one-way messages (`send`) | 1 629 | 434 | 365 | 800 |

Throughput falls as senders are added, and the empty service falls as the
rate limiter does: the cost is the round trip between isolates (the reply
to another port and waking its isolate), not the service. At 8 senders
there is no oversubscription of the 8 physical cores, and it has fallen
already. One-way messages cost far less. Leases stay exact: limits of 60,
1 000 and 10 000 per minute from 4 and 16 isolates never allowed one
attempt over the limit, at no more than 0.0006 coordinator messages per
decision.

**Saturation.** A rate limit attempt alone answers in p99 88-107 µs; while
16 isolates publish broadcasts as fast as they can (about 44 000 a second)
its p99 is 32.5-35.7 ms. Priorities in the coordinator (K1) leave it about
the same (29.5-32.5 ms): the waiting happens in the coordinator's port,
before any priority applies, so the pressure has to be held back at the
senders (K1b).

## Public run

`bench/public.sh` (Linux and Docker) produces the numbers meant for
publication. Run it on a machine that does nothing else, preferably with
dedicated vCPUs:

```bash
bash bench/public.sh                                   # about an hour on 8 cores
RUNS=1 DURATION=3 CURVE=16,64 bash bench/public.sh     # a quick dry run
```

1. It records the machine and the versions (`environment.txt`: CPU model,
   cores and threads per core, memory, virtualisation, CPU governor,
   kernel, Docker, the Dart image digest, PHP, FrankenPHP, Laravel, Octane,
   PostgreSQL, oha, the commit, the load before the run).
2. It runs `compare.sh` `RUNS` times (5) at 64 connections. The report
   gives the median and the lowest and highest value of each scenario, so a
   noisy run shows as spread.
3. It repeats the database scenarios (`PG_SCENARIOS`, 2 to 4, 11 and 12) on
   PostgreSQL, `RUNS` times as well; `PG_SCENARIOS=` skips them.
4. It runs scenarios 11 (closed loop) and 12 (open loop) on Daravel `RUNS`
   times: `OVERLOAD_CONNECTIONS` (512) against no limit, `MAX_IN_FLIGHT`
   (32) and `MAX_QUEUE_DELAY` (50 ms) added.
5. It measures a saturation curve: `CURVE_SCENARIOS` (1 and 2) at `CURVE`
   connections (16, 64, 256, 1024) for Daravel, Octane and classic with
   `WORKERS` workers, and dart:io as the reference for `/ping`.
6. It cross-checks the harness with [oha](https://github.com/hatoo/oha)
   (pinned, checksum verified), a load generator written in Rust, against
   Daravel (`bench.dart --serve`) and Octane on the GET scenarios 1, 2 and 4.
7. `bin/public_report.dart` writes `report.md` and `summary.json`.

Everything lands in `bench/results/<date>-<host>/` with the raw JSON of
every run, so a published number can be traced to its measurements.
Servers use the first half of the cores and load generators the second
(`SERVER_CPUS`, `CLIENT_CPUS`).

Startup is measured by polling `/up`. On Windows a refused connection takes
about 0.5 s to report, so startup numbers there are dominated by the poll and
are not comparable with Linux.
