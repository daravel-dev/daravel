#!/usr/bin/env bash
# K1b re-measurement (ACK 233 §1, ACK 235 Addendum 2 A, ACK 236 §3):
# main (origin/main d4f973fe, built with K1b's bench file adapted to main's
# API) against K1b W 16. Each operation runs alone (20 s per point,
# 1/8/16 senders), started only once the 1-minute load is below 2; the
# order of operations rotates between rounds. Ceiling: five rounds.
# Saturation, overflow (K1b, a 64-call buffer), starved (16 CPU burners, no
# flood) and leases: three rounds.
set -uo pipefail
DART="$HOME/.local/share/dart-sdks/3.13.4/bin/dart"
export PUB_CACHE="$HOME/.pub-cache"
SRC=$SCRATCH/k1b_bench
STAMP=$(date +%Y%m%d-%H%M%S)
WORK="$HOME/k1b-bench2-$STAMP"
OUT="$SRC/remeasure2-$STAMP"
mkdir -p "$WORK" "$OUT"
echo "work=$WORK" > "$OUT/loads.txt"

build() {
  local name=$1 tarball=$2
  local dst="$WORK/$name"
  mkdir -p "$dst"
  tar -xf "$SRC/$tarball" -C "$dst"
  if [ "$name" = main ]; then
    # K1b's bench file on main's API: no bulk window or buffer there.
    sed -e '/bulkWindow: job.window,/d' -e '/bulkBuffer: job.buffer,/d' \
      -e 's/RemoteCoordinatorChannel.defaultBulkWindow/16/g' \
      -e 's/RemoteCoordinatorChannel.defaultBulkBuffer/1024/g' \
      "$SRC/ceiling_for_main.dart" > "$dst/bench/bin/coordinator_ceiling.dart"
  fi
  cd "$dst" && [ "$(pwd)" = "$dst" ] || exit 1
  "$DART" pub get > "$OUT/pubget-$name.txt" 2>&1 || exit 1
  cd "$dst/bench" && [ "$(pwd)" = "$dst/bench" ] || exit 1
  "$DART" build cli -t bin/coordinator_ceiling.dart -o build/ceiling > "$OUT/build-$name.txt" 2>&1 || {
    echo "build $name failed" >> "$OUT/loads.txt"; exit 1; }
}
build main main2.tar
build k1b k1b2.tar
MAIN="$WORK/main/bench/build/ceiling/bundle/bin/coordinator_ceiling"
K1B="$WORK/k1b/bench/build/ceiling/bundle/bin/coordinator_ceiling"

load1() { cut -d' ' -f1 /proc/loadavg; }
settle() {
  local waited=0
  while awk -v l="$(load1)" 'BEGIN { exit !(l >= 2) }'; do
    if [ "$waited" -ge 1200 ]; then
      echo "load still $(load1) after 20 min" >> "$OUT/loads.txt"; return
    fi
    sleep 15; waited=$((waited + 15))
  done
}
run() {  # name binary args...
  local name=$1 binary=$2; shift 2
  settle
  echo "$name load: $(cut -d' ' -f1-3 /proc/loadavg)" >> "$OUT/loads.txt"
  "$binary" --duration=20 --clients=1,8,16 --json "$@" > "$OUT/$name.json" 2> "$OUT/$name.err"
  echo "$name exit=$?" >> "$OUT/loads.txt"
}

OPS=(rate cache noop publish)
for round in 1 2 3 4 5; do
  shift_by=$(( (round - 1) % 4 ))
  order=("${OPS[@]:$shift_by}" "${OPS[@]:0:$shift_by}")
  for op in "${order[@]}"; do
    run "main_ceiling-${op}_$round" "$MAIN" --sections=ceiling --ops="$op"
    run "k1b_ceiling-${op}_$round" "$K1B" --sections=ceiling --ops="$op" --window=16
  done
  if [ "$round" -le 3 ]; then
    run "main_saturation_$round" "$MAIN" --sections=saturation
    run "k1b_saturation_$round" "$K1B" --sections=saturation --window=16
    run "k1b_overflow_$round" "$K1B" --sections=saturation --window=16 --buffer=64
    run "main_starved_$round" "$MAIN" --sections=starved
    run "k1b_starved_$round" "$K1B" --sections=starved --window=16
    run "main_lease_$round" "$MAIN" --sections=lease
    run "k1b_lease_$round" "$K1B" --sections=lease --window=16
  fi
done
echo done >> "$OUT/loads.txt"
