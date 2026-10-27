# Benchmarks

Daravel publishes a number only with the script that produced it, the
machine it ran on and the raw measurements (BLUEPRINT_V2 P10). This page
compares Daravel with Laravel 12 doing the same work. The harness and the
internal targets are in [Performance](performance.md).

## What is compared

Three servers answer the same six endpoints, on the same database and the
same cores:

- **Daravel**: the AOT build, with 1 and 4 worker isolates.
- **Laravel Octane**: Laravel 12 on PHP 8.4 with OPcache, on FrankenPHP's
  worker mode (the application stays in memory between requests), with 1
  and 4 workers.
- **Laravel classic**: the same Laravel on FrankenPHP without worker mode,
  which boots the application for every request, as php-fpm does.

| Scenario | Endpoint | Work |
| :-- | :-- | :-- |
| framework overhead | `GET /ping` | a text response, no database |
| JSON + one query | `GET /api/users/42` | `findOrFail`, the model as JSON |
| validation + insert | `POST /api/users` | two rules, an insert in a transaction |
| eager loading | `GET /api/posts` | 20 posts with their author and 10 comments each |
| rate limited route | `GET /api/throttled` | `throttle` with a limit never reached |
| login | `POST /api/login` | find a user, verify a bcrypt hash (cost 10) |

The Laravel endpoints in `bench/laravel/overlay/` mirror
`bench/lib/bench_app.dart`: the same routes, validation rules, queries and
responses. Laravel's configuration, routes and events are cached, as in
production. Daravel seeds the database (1 000 users, 200 posts, 2 000
comments) and Laravel verifies its `$2y$` hashes as they are.

## How a published run is made

`bench/public.sh` runs everything on one Linux machine with Docker, and
writes the results into `bench/results/<date>-<host>/`:

1. **The environment**: CPU model, cores and threads per core, memory,
   virtualisation, CPU governor, kernel, Docker, the digest of the Dart
   image, PHP, FrankenPHP, Laravel, Octane, PostgreSQL, oha, the commit,
   and the load and containers on the machine before the run.
2. **Five runs** of every scenario, 10 seconds each after a 2-second
   warm-up, at 64 keep-alive connections. A table gives the median, with the
   lowest and highest run beside it, so one noisy run shows as spread
   instead of moving the number.
3. **PostgreSQL**: the scenarios that query (2 to 4), five runs again,
   against a fresh PostgreSQL 17 server.
4. **Overload**: Daravel alone (Laravel has no equivalent) flooded with
   512 connections on scenario 2's endpoint, without a limit, with
   `HTTP_MAX_IN_FLIGHT` and with `HTTP_MAX_QUEUE_DELAY` added
   ([load shedding](deployment.md#load-shedding)): goodput, p99 of the
   successful requests and the share refused with `503`, five runs.
5. **A saturation curve**: `/ping` and the JSON scenario at 16, 64, 256 and
   1 024 connections, with plain `dart:io` as the ceiling for `/ping`.
6. **A second load generator**: [oha](https://github.com/hatoo/oha),
   written in Rust (pinned version, checksum verified), measures Daravel
   and Octane on the GET scenarios. If its numbers and the harness's agree,
   the results do not come from the Dart load generator.
7. **The raw data**: the JSON of every run stays next to `report.md` and
   `summary.json`.

The servers (and PostgreSQL) run on the first half of the cores and the
load generators on the second half, so they never compete for a core.

### Differences that remain

- Laravel's rate limiter uses the `array` cache, so each Octane worker
  counts on its own; Daravel's limit is shared by every isolate through
  the coordinator, which costs a message per request.
- `/ping` is registered outside Laravel's `web` middleware group (no
  session, no CSRF), as Daravel's `/ping` has none.
- On PostgreSQL, Daravel keeps a pool of 4 connections per isolate, while
  PHP holds one connection per Octane worker, and classic connects for
  every request. Each is the runtime's normal setup.
- SQLite is a file on the same disk for every server: Daravel's and
  Laravel's drivers both use WAL, `busy_timeout` 5000 and
  `synchronous=NORMAL`.

The first two favour Laravel.

## Results

### Published runs

None yet. A run on a dedicated machine is listed here with its
environment, its tables and a link to its raw data in `bench/results/`.

### Indicative run

One run on 2026-10-26: WSL2 on a 16-thread laptop, with other containers
running, 10 s per scenario, 64 connections, four workers, SQLite. A single
run on a shared machine, so read the ratios rather than the absolute
numbers.

| Scenario | Daravel | Laravel Octane | Laravel classic |
| :-- | --: | --: | --: |
| `GET /ping` | 12 160 req/s | 2 254 req/s | 983 req/s |
| JSON + one query | 9 594 req/s | 1 843 req/s | 720 req/s |
| validation + insert | 2 918 req/s | 1 079 req/s | 551 req/s |
| eager loading (20 posts) | 1 876 req/s | 440 req/s | 300 req/s |
| rate limited route | 10 494 req/s | 1 721 req/s | 902 req/s |
| login (bcrypt, cost 10) | 35 req/s (61 since 1.10) | 72 req/s | 68 req/s |

With one worker Daravel served 6 to 10 times Octane's throughput on the
first five scenarios. Login was the exception: `package:bcrypt` in pure
Dart took 124 ms per hash where PHP's C bcrypt takes 70 ms. Since 1.10
Daravel runs the system's C bcrypt on Linux (see [Hashing](auth.md#hashing));
a second run of the login scenario on the same machine gave Daravel
61 req/s, Octane 55 and classic 47, so login costs what it costs in
Laravel.

For WebSocket connections (10 000 Laravel Echo clients on one server), see
[Broadcasting](broadcasting.md#capacity).

## Reading the numbers

- **Throughput and p99 together.** Requests per second say how much a
  server can do; p99 says what the slowest one in a hundred users waits.
  Under a fixed number of connections, latency is mostly time in the
  queue, so a faster server also has a lower p99.
- **The saturation curve.** While connections grow, throughput first rises
  and then stays flat while p99 keeps climbing: from there on, more
  clients only wait longer. Errors in the curve are responses of 400 or
  more and failed connections.
- **Per core.** Every server gets the same cores. Four workers on four
  cores is the fair comparison; one worker shows the cost of a single
  request path.
- **Your own hardware.** The script needs Linux, Docker and four cores or
  more. Run it before relying on any number here.

## Run it yourself

```bash
git clone https://github.com/daravel-dev/daravel && cd daravel
bash bench/public.sh                                  # about an hour on 8 cores
RUNS=1 DURATION=3 CURVE=16,64 bash bench/public.sh    # a quick dry run
cat bench/results/*/report.md
```

`bench/laravel/compare.sh` runs a single comparison (`DB=pgsql` for
PostgreSQL, `CONNECTIONS=16,64,256` for several connection counts). The
settings of both are in
[bench/README.md](https://github.com/daravel-dev/daravel/blob/main/bench/README.md).
