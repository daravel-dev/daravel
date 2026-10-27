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

## Against Laravel

Daravel against Laravel 12 (Octane and classic) on the same scenarios,
with the method, the results and how to reproduce them, is on its own
page: [Benchmarks](benchmarks.md).
