#!/usr/bin/env bash
# K1b refusal timing (ACK 247 §3 item 5): the bench harness WITHOUT its
# yield-after-error fix (16323917 removed by one sed), so a flood lane
# retries a refusal at once. Two lib variants from one tarball (f0d826b1):
#   p:    a refusal fails on the next turn (the committed code);
#   p1ms: the same, from a 1 ms timer instead of Timer.run (built-in back-off).
# Overflow (16-call buffer) three times each, alternating; starved three
# times and saturation once on p (controls).
set -uo pipefail
DART="$HOME/.local/share/dart-sdks/3.13.4/bin/dart"
export PUB_CACHE="$HOME/.pub-cache"
SRC=${SRC:?set SRC}
STAMP=$(date +%Y%m%d-%H%M%S)
WORK="$HOME/k1b-refusal-$STAMP"
OUT="$SRC/refusal-$STAMP"
mkdir -p "$WORK" "$OUT"
echo "work=$WORK" > "$OUT/loads.txt"
build() {
  local name=$1 dst="$WORK/$1"
  mkdir -p "$dst" && tar -xf "$SRC/k1b5.tar" -C "$dst"
  sed -i '/await Future<void>.delayed(Duration.zero);/d' "$dst/bench/bin/coordinator_ceiling.dart"
  grep -q 'await Future<void>.delayed(Duration.zero);' "$dst/bench/bin/coordinator_ceiling.dart" && { echo "bench sed missed" >> "$OUT/loads.txt"; exit 1; }
  if [ "$name" = p1ms ]; then
    sed -i 's/    () => Timer.run(() {/    () => Timer(const Duration(milliseconds: 1), () {/' "$dst/packages/daravel/lib/src/server/coordinator.dart"
    grep -q 'Timer(const Duration(milliseconds: 1), () {' "$dst/packages/daravel/lib/src/server/coordinator.dart" || { echo "p1ms sed missed" >> "$OUT/loads.txt"; exit 1; }
  fi
  cd "$dst" && "$DART" pub get > "$OUT/pubget-$name.txt" 2>&1 || exit 1
  cd "$dst/bench" && "$DART" build cli -t bin/coordinator_ceiling.dart -o build/ceiling > "$OUT/build-$name.txt" 2>&1 || { echo "build $name failed" >> "$OUT/loads.txt"; exit 1; }
}
build p
build p1ms
bin() { echo "$WORK/$1/bench/build/ceiling/bundle/bin/coordinator_ceiling"; }
load1() { cut -d' ' -f1 /proc/loadavg; }
settle() {
  local waited=0
  while awk -v l="$(load1)" 'BEGIN { exit !(l >= 2) }'; do
    [ "$waited" -ge 1200 ] && { echo "load still $(load1) after 20 min" >> "$OUT/loads.txt"; return; }
    sleep 15; waited=$((waited + 15))
  done
}
run() {
  local name=$1 binary=$2; shift 2
  settle
  echo "$name load: $(cut -d' ' -f1-3 /proc/loadavg)" >> "$OUT/loads.txt"
  "$binary" --duration=20 --clients=1,8,16 --json "$@" > "$OUT/$name.json" 2> "$OUT/$name.err"
  echo "$name exit=$?" >> "$OUT/loads.txt"
}
for round in 1 2 3; do
  run "p_overflow_$round" "$(bin p)" --sections=saturation --window=16 --buffer=16
  run "p1ms_overflow_$round" "$(bin p1ms)" --sections=saturation --window=16 --buffer=16
done
for round in 1 2 3; do
  run "p_starved_$round" "$(bin p)" --sections=starved --window=16
done
run "p_saturation_1" "$(bin p)" --sections=saturation --window=16
echo done >> "$OUT/loads.txt"
