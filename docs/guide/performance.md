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
7. a 64 KB multipart upload, parsed and read,
8. an SSE response of ten events, read to its end,
11. overload: scenario 2 under far more connections than the workers can
    serve, without a limit, with `HTTP_MAX_IN_FLIGHT`, and with
    `HTTP_MAX_QUEUE_DELAY` added (see [Deployment](deployment.md#load-shedding)),
    with clients that retry at once (closed loop),
12. the same three servers at a fixed arrival rate 1.5 times their capacity,
    from clients that do not retry (open loop, the case load shedding is
    for),

plus a Zone/facade microbenchmark, startup time and idle RSS for each
isolate count. Every scenario is also expressed relative to a plain
`dart:io` server measured in the same run; the nightly workflow fails when
that ratio drops by more than 10% against `bench/baseline.json`.

Internal targets (not public promises): `/ping` within 25% of `dart:io`,
throttling adds at most 100 µs of service time per
request, and four isolates give at least three times the throughput of one on a 4+ core machine. See
[bench/README.md](https://github.com/daravel-dev/daravel/blob/main/bench/README.md)
for the methodology.

## Your application under load

`bench/` measures the framework. `dartisan test:stress` measures your
application, running wherever you point it (local, DDEV, staging): it
finds what the application has, warms it up, sends rounds of requests over
several connections and client isolates, and reports the throughput of the
rounds (mean ± standard deviation) and the p50/p95/p99 latency.

```bash
dartisan serve                                   # in another terminal
dartisan test:stress --rounds=5 --requests=2000 --concurrency=50
dartisan test:stress --url=https://shop.ddev.site --path=/api/products
```

| Scenario | Request | Expected |
|---|---|---|
| `health` | `GET /up` | 200 |
| `ping` | `GET /api/ping` | 200 |
| `not_found` | an unknown route | 404 |
| `auth_me` | `GET /api/auth/me` with the token of a user it registers (`stress_…@example.test`) | 200 |
| `rate_limit` | failed logins for one email | 422, then 429 |
| `custom_N` | `GET` of each `--path` | 200 |

Only the scenarios the application answers run; `--scenario=ping,auth_me`
picks some. Any 5xx, request without a response or unexpected status
fails the run (exit 1), and so do `--max-p95=150` (milliseconds) and
`--min-rps=500`, which makes it a performance gate in CI. The login
scenario is held to its statuses only, since password hashing makes it slow
on purpose.

`--json=report.json` keeps everything, the target included.
`--export-public=benchmarks.json` writes what may be published: statistics
by scenario, statuses by class (`2xx`, `4xx`), the settings, and the
operating system, CPU count and Dart and Daravel versions. It is built from
a list of allowed fields, so the URL, host and port, tokens, the synthetic
user and the `--path` routes cannot reach it. Before you publish a number,
say what produced it: the machine, whether the load generator shared it,
and how many rounds.

## Against Laravel

Daravel against Laravel 12 (Octane and classic) on the same scenarios,
with the method, the results and how to reproduce them, is on its own
page: [Benchmarks](benchmarks.md).
