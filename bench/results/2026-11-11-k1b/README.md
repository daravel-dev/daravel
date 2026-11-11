# K1b results, 2026-11-11

Raw files for Blueprint #141 §6.4–§6.8 (K1b: bulk credit window,
queue-evidence state, refusal ticks). All runs are `coordinator_ceiling`
AOT binaries in WSL2 on one laptop (16 logical CPUs), each run started once
the 1-minute load was below 2 (`settle` in the scripts).

**What these numbers are not:** throughput across machines, or absolute
capacity. They compare branches on the same machine and day, over loopback
ports.

**p99 resolution:** p99 values are histogram bucket edges (buckets grow by
10 %), not continuous measurements. "< 5 ms" means "in the bucket at or
below 4.83 ms", and 4.39 / 4.83 / 5.31 ms are neighbouring buckets.

**The main build** uses K1b's bench file, adapted to main's API by one
`sed` in each script. The `sed` drops `bulkWindow:`/`bulkBuffer:` and
replaces the two default constants by 16 and 1024.

## Folders

| Folder | What | Used for |
| :-- | :-- | :-- |
| `final/` | **final code** (lib e735517a): ceiling 5 rounds × 20 s (rate, cache, noop, publish × 1/8/16), saturation 3, starved 3, lease 1, overflow 1 (`final.sh`, `summary.txt`) | the PR's criteria table |
| `refusal2-20261111-142313/` | refusal ticks, pa (committed, 0de7d0d3) against p1ms (1 ms always): overflow 3 each, alternating; pa starved 3, saturation 1 (`refusal2.sh`) | overflow, refusal ticks |
| `refusal-20261111-140327/` | refusal on the next turn only (p, 75ef695a) against p1ms: overflow 3 each; p starved 3, saturation 1 (`refusal.sh`) | the "before" of refusal ticks |
| `overflow-20261111-135243/` | overflow 3 with the harness yielding one turn after a refusal (16323917, reverted in 79a977b0) | the "before" |
| `variants/` | publish refill variants (a) and (b) against main and K1b, 3 rounds | choosing the refill rule (K1b unchanged kept, ACK 244) |
| `remeasure2-before-b/` | 61 runs on the code before B (§6.6 queue evidence) | "before" evidence only |
| `series1/` | W 8/16/32, 5 s per point | not used: load 4.3–7.4 at start from run 2 on; W 8/W 32 ceiling clients ran with W 16 (harness bug, fixed) |
| `flake/` | `supervisor_test` "process-scope state" under 16 CPU burners (Windows) | regression of K1 and its fix |

## Final code (`final/`, plus refusal ticks)

- **Saturation:** p99 of a rate limit under a 16-isolate publish flood is 32.5 ms on main and 3.99 ms (3.99–4.39) on K1b. Publishes are 39.8k/s on main and 155.9k/s on K1b. Nothing refused, no probe errors. p99 of a rate limit alone is 80 µs on both.
- **Starved** (16 CPU burners, no flood): K1b stays `healthy` with 0 publishes or rate limits failed, as on main. Before §6.6, K1b refused 6.2–9.4 million publishes there (`remeasure2-before-b/`).
- **Leases:** never over the limit on either branch.
- **Healthy ceiling:** no cell has a median more than 3 % below main *and* a min–max range apart from main's. The medians of `publish` × 1 (−8.2 %), `publish` × 8 (−8.5 %) and `cache` × 1 (−8.7 %) are still below main, with ranges overlapping main's over 5 rounds (`final/summary.txt`). `cache` × 1 is measured again, alone, 10 rounds (below).
- **Overflow** (16-call buffer, a flood of 64 in flight against a window of 16):

  | Variant | p99 of a rate limit |
  | :-- | :-- |
  | Refusals as already failed futures | 21.2 s (`final/`) |
  | The same, the harness yielding one turn after each refusal | 1.96–4.62 s (`overflow-*`) |
  | Refusals on the next turn (p) | 4.6–9.9 s (`refusal-*`) |
  | **Refusal ticks (pa)** | **4.83 ms** in all three runs (`refusal2-*`) |
  | p1ms | 4.39–5.31 ms |

  - The saturation control is 4.39 ms. pa and p1ms both meet the criterion (≤ 2×), and differ by one bucket. pa was chosen because an occasional refusal still costs only one turn.
  - Publishes that get through stay around 150k/s while about 3 million a run are refused, so cheap refusals do not lower the accepted throughput.
- **The harness models the worst sender.** Its flood retries a refused call at once, with no pause: the product, not the harness, holds such a sender back (79a977b0 reverted the harness's own pause).

## Flake (`flake/`)

`supervisor_test` "process-scope state", 16 CPU burners, Windows:

| Code | Failed |
| :-- | --: |
| main d4f973fe | 0 / 30 |
| K1 | 19 / 27 |
| K1b before the §6.6 fix | 21 / 26 |
| K1b e735517a | 0 / 30 |
| K1b 0de7d0d3 (refusal ticks) | 0 / 30 |
| K1b 9758215b (Review #153 fixes) | 0 / 30 |
