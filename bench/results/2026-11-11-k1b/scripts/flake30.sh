#!/usr/bin/env bash
# supervisor_test "process-scope state": 30 runs on K1 and 30 on K1b,
# alternating, under 16 CPU burners (as the earlier race repro).
OUT=$SCRATCH/flake30
mkdir -p "$OUT"
burners=()
for i in $(seq 1 16); do
  ( while :; do :; done ) &
  burners+=($!)
done
trap 'kill "${burners[@]}" 2>/dev/null' EXIT
for i in $(seq 1 30); do
  for name in k1 k1b; do
    dir=/d/daravel-$name/packages/daravel
    cd "$dir" || exit 1
    fvm dart test test/server/supervisor_test.dart --name "process-scope state" \
      > "$OUT/$name-$i.txt" 2>&1
    echo "$name $i exit=$?" >> "$OUT/summary.txt"
  done
done
echo done >> "$OUT/summary.txt"
