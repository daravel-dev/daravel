#!/usr/bin/env bash
# K1b re-measurement (ACK 233 §1): main against W 16, 20 s per point, five
# runs alternating, each started only once the 1-minute load is below 2
# (at most 20 minutes of waiting; the load at start is logged). Each run
# measures the healthy ceiling, saturation and leases.
set -uo pipefail
SRC=$SCRATCH/k1b_bench
WORK="$HOME/k1b-bench-20261111-074622"
MAIN="$WORK/main/bench/build/ceiling/bundle/bin/coordinator_ceiling"
K1B="$WORK/k1b/bench/build/ceiling/bundle/bin/coordinator_ceiling"
STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$SRC/remeasure-$STAMP"
mkdir -p "$OUT"
ls "$MAIN" "$K1B" > "$OUT/binaries.txt" || exit 1

load1() { cut -d' ' -f1 /proc/loadavg; }

settle() {
  local waited=0
  while awk -v l="$(load1)" 'BEGIN { exit !(l >= 2) }'; do
    if [ "$waited" -ge 1200 ]; then
      echo "load still $(load1) after 20 min" >> "$OUT/loads.txt"
      return
    fi
    sleep 15
    waited=$((waited + 15))
  done
}

run() {
  local name=$1 binary=$2
  shift 2
  settle
  echo "$name load: $(cut -d' ' -f1-3 /proc/loadavg)" >> "$OUT/loads.txt"
  "$binary" --duration=20 --clients=1,8,16 --json "$@" > "$OUT/$name.json" 2> "$OUT/$name.err"
  echo "$name exit=$?" >> "$OUT/loads.txt"
}

for round in 1 2 3 4 5; do
  run "main_$round" "$MAIN"
  run "k1b-w16_$round" "$K1B" --window=16
done
echo done >> "$OUT/loads.txt"
