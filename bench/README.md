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
