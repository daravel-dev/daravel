# K1b results, 2026-11-11 (work in progress)

Raw files for Blueprint #141 §6.4/§6.5 (K1b: bulk credit window). Not quoted
in the README yet.

| Folder | What | Status |
| :-- | :-- | :-- |
| `series1/` | `coordinator_ceiling` AOT, 5 s per point, 1/8/16 senders; main against K1b with `--window` 8, 16, 32, three rounds alternating (`scripts/run.sh`) | complete (12 runs), but the load at start was 4.3-7.4 from run 2 on: not for the README |
| `flake/summary.txt` | `supervisor_test.dart` "process-scope state", K1 against K1b alternating, under 16 CPU burners (`scripts/flake30.sh`) | stopped at a checkpoint after 27 (K1) and 26 (K1b) runs |

Series 1, medians (`scripts/summary.dart series1`): p99 of a rate limit attempt
under a 16-isolate publish flood 35.7 ms (main), 4.39 ms (W 8, W 16), 4.83 ms
(W 32; one run 5.31 ms); publishes 39.8k/s (main), 80.0k, 157.7k, 279.3k;
port messages per 1 000 publishes 259, 130, 65; none refused; leases never
over the limit. The healthy ceiling varied 5-15 % between runs of one variant,
too much to judge a 3 % criterion.

Next: `scripts/remeasure.sh` (main against W 16, 20 s per point, five runs,
each started below a 1-minute load of 2), approved in ACK 233.

p99 values are histogram bucket edges (buckets grow by 10 %), not continuous
measurements: "< 5 ms" means "in the bucket at or below 4.83 ms".
