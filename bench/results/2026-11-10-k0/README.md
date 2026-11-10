# K0 results, 2026-11-10

The raw files behind the "coordinator" section of [bench/README.md](../../README.md),
as `compare.sh` and `coordinator_ceiling.dart` wrote them. Each `loads.txt`
lists the runs in order with the 1-minute load at their start and their
exit code.

| Folder | What | In the README |
| :-- | :-- | :-- |
| `k0_pgsql/pgsql-redis-{1,2,3}` | `DB=pgsql CACHE_VARIANT=redis`, Sanctum defaults | the headline table |
| `k0_pgsql/pgsql-redis-nolastused-{1,2,3}` | the same with `SANCTUM_LAST_USED_AT=false` | `last_used_at` |
| `k0_followup/redis-1b`, `k0_series/redis-{2,3}` | SQLite, `CACHE_VARIANT=redis` | SQLite against PostgreSQL |
| `k0_last/process-1b`, `k0_followup/process-2b`, `k0_series/process-3` | SQLite, `CACHE_VARIANT=process` | the `process` cache |
| `k0_last/pool{4,8}` | scenario 14, `PG_POOL` 4 and 8, one run each | the pool explainer |
| `k0_followup/ceiling-main_{1,2,3}.json` | the ceiling, saturation and leases on this branch | the coordinator's ceiling |
| `k0_followup/ceiling-k1_{1,2,3}.json` | the same against K1's core | saturation with K1 |
| `k0_series/ceiling_{1,2,3}.json` | an earlier ceiling run, without `noop` and `send` | (not quoted) |

Left out of the README: `k0_series/process-{1,2}` and `k0_series/redis-1`,
which fell about 4× on both sides while the host compiled and generated
docs, and were redone (`process-1b`, `process-2b`, `redis-1b`).

Recompute the tables:

```bash
cd bench
dart run bin/runs_summary.dart results/2026-11-10-k0/k0_pgsql/pgsql-redis-{1,2,3}
dart run bin/ceiling_summary.dart results/2026-11-10-k0/k0_followup/ceiling-main_*.json
```
