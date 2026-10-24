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

Scenarios 7 (5 MB multipart) and 8 (1 000 idle SSE connections) wait for
multipart and SSE support (Tier 2).

The database is SQLite (`build/bench.sqlite`, seeded with 1 000 users,
200 posts, 2 000 comments). The Postgres variant of scenarios 2–4 is not
wired up yet.

## Reading the results

Absolute requests per second depend on the machine, and the load generator
shares it with the server. Each scenario is therefore also reported as
`relative_to_dartio`: its throughput divided by the plain `dart:io` server
measured in the same run with the same isolate count. `--compare` gates on
that ratio, which is what the nightly workflow (`.github/workflows/bench.yml`)
uses. To set the baseline, copy a nightly `results.json` artifact to
`bench/baseline.json` and commit it.

Internal targets (§10.2, not public promises) are printed at the end:
ping overhead ≤ 25% against `dart:io`, throttle adds ≤ 100 µs p50, and four
isolates give ≥ 3× the ping throughput of one on a 4+ core machine.

Startup is measured by polling `/up`. On Windows a refused connection takes
about 0.5 s to report, so startup numbers there are dominated by the poll and
are not comparable with Linux.
