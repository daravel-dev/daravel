# Performance

Daravel makes no performance claim without a reproducible number
(BLUEPRINT_V2 P10). The harness in `bench/` builds the servers AOT and
measures them:

```bash
cd bench
dart run bin/bench.dart --duration=10 --isolates=1,4 --out=results.json
```

It reports requests per second and p50/p95/p99 latency for:

1. `GET /ping` (framework overhead),
2. JSON plus one query,
3. validation plus an insert in a transaction,
4. eager loading two relations,
5. a throttled route (coordinator cost),
6. login (bcrypt in the compute pool),

plus a Zone/facade microbenchmark, startup time and idle RSS for each
isolate count. Every scenario is also expressed relative to a plain
`dart:io` server measured in the same run; the nightly workflow fails when
that ratio drops by more than 10% against `bench/baseline.json`.

Internal targets (not public promises): `/ping` within 25% of `dart:io`,
throttling adds at most 100 µs of service time per
request, and four isolates give at least three times the throughput of one on a 4+ core machine. See
[bench/README.md](https://github.com/daravel-dev/daravel/blob/main/bench/README.md)
for the methodology.

## Against Laravel

`bench/laravel/compare.sh` runs the same scenarios against Laravel 12.70 on
PHP 8.4 with OPcache: as Laravel Octane on FrankenPHP's worker mode, and as
classic FrankenPHP, which boots the application for every request like
php-fpm. The endpoints do the same work, on one SQLite database with the
same settings, and every server runs on the same four cores, apart from the
load generator. The method and the two differences that favour Laravel are
in [bench/README.md](https://github.com/daravel-dev/daravel/blob/main/bench/README.md#against-laravel).

One run on 2026-10-26 (WSL2 on a 16-thread laptop, other containers
running, 10 s per scenario, 64 connections), four workers:

| Scenario | Daravel | Laravel Octane | Laravel classic |
| :-- | --: | --: | --: |
| `GET /ping` | 12 160 req/s | 2 254 req/s | 983 req/s |
| JSON + one query | 9 594 req/s | 1 843 req/s | 720 req/s |
| validation + insert | 2 918 req/s | 1 079 req/s | 551 req/s |
| eager loading (20 posts) | 1 876 req/s | 440 req/s | 300 req/s |
| rate limited route | 10 494 req/s | 1 721 req/s | 902 req/s |
| login (bcrypt, cost 10) | 35 req/s | 72 req/s | 68 req/s |

With one worker Daravel served 6 to 10 times Octane's throughput on the
first five scenarios. Login is the exception: bcrypt in pure Dart is slower
than PHP's C implementation, and Daravel's compute pool does not grow with
the isolate count, so Laravel answers twice as many logins with four
workers. Throughput is not the only cost of a login, but this is the
scenario to improve. Run the script on your own hardware before relying on
these numbers.
