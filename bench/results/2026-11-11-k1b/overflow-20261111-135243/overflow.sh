#!/usr/bin/env bash
# K1b overflow re-run (bench fix 16323917: a refused call yields one turn):
# K1b code unchanged (e735517a lib), the bench harness at 16323917.
# Overflow with a 16-call buffer three times, and saturation once to check
# the harness change leaves the flood that waits for credit unchanged.
set -uo pipefail
DART="$HOME/.local/share/dart-sdks/3.13.4/bin/dart"
export PUB_CACHE="$HOME/.pub-cache"
SRC=${SRC:?set SRC}
STAMP=$(date +%Y%m%d-%H%M%S)
WORK="$HOME/k1b-overflow-$STAMP"
OUT="$SRC/overflow-$STAMP"
mkdir -p "$WORK/k1b" "$OUT"
echo "work=$WORK" > "$OUT/loads.txt"
tar -xf "$SRC/k1b4.tar" -C "$WORK/k1b"
cd "$WORK/k1b" && "$DART" pub get > "$OUT/pubget.txt" 2>&1 || exit 1
cd "$WORK/k1b/bench" && "$DART" build cli -t bin/coordinator_ceiling.dart -o build/ceiling > "$OUT/build.txt" 2>&1 || { echo "build failed" >> "$OUT/loads.txt"; exit 1; }
K1B="$WORK/k1b/bench/build/ceiling/bundle/bin/coordinator_ceiling"
load1() { cut -d' ' -f1 /proc/loadavg; }
settle() {
  local waited=0
  while awk -v l="$(load1)" 'BEGIN { exit !(l >= 2) }'; do
    [ "$waited" -ge 1200 ] && { echo "load still $(load1) after 20 min" >> "$OUT/loads.txt"; return; }
    sleep 15; waited=$((waited + 15))
  done
}
run() {
  local name=$1; shift
  settle
  echo "$name load: $(cut -d' ' -f1-3 /proc/loadavg)" >> "$OUT/loads.txt"
  "$K1B" --duration=20 --clients=1,8,16 --json "$@" > "$OUT/$name.json" 2> "$OUT/$name.err"
  echo "$name exit=$?" >> "$OUT/loads.txt"
}
for round in 1 2 3; do
  run "k1b_overflow_$round" --sections=saturation --window=16 --buffer=16
done
run "k1b_saturation_1" --sections=saturation --window=16
echo done >> "$OUT/loads.txt"
