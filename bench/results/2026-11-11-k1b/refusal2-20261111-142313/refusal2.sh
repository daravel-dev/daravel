#!/usr/bin/env bash
# K1b refusal timing, adaptive (ACK 248 §2): the bench harness WITHOUT its
# yield-after-error fix (16323917 removed by one sed), so a flood lane
# retries a refusal at once. Two lib variants from one tarball (c806ffd9):
#   pa:   a refusal tick waits 1 ms only in a storm (the committed code);
#   p1ms: every tick waits 1 ms (one sed: storm = true).
# Overflow (16-call buffer) three times each, alternating; starved three
# times and saturation once on pa (controls).
set -uo pipefail
DART="$HOME/.local/share/dart-sdks/3.13.4/bin/dart"
export PUB_CACHE="$HOME/.pub-cache"
SRC=${SRC:?set SRC}
STAMP=$(date +%Y%m%d-%H%M%S)
WORK="$HOME/k1b-refusal2-$STAMP"
OUT="$SRC/refusal2-$STAMP"
mkdir -p "$WORK" "$OUT"
echo "work=$WORK" > "$OUT/loads.txt"
build() {
  local name=$1 dst="$WORK/$1"
  mkdir -p "$dst" && tar -xf "$SRC/k1b6.tar" -C "$dst"
  sed -i '/await Future<void>.delayed(Duration.zero);/d' "$dst/bench/bin/coordinator_ceiling.dart"
  grep -q 'await Future<void>.delayed(Duration.zero);' "$dst/bench/bin/coordinator_ceiling.dart" && { echo "bench sed missed" >> "$OUT/loads.txt"; exit 1; }
  if [ "$name" = p1ms ]; then  # storm always: 1 ms per tick
    sed -i 's/^  final storm =$/  final storm = true ||/' "$dst/packages/daravel/lib/src/server/coordinator.dart"
    grep -q 'final storm = true ||' "$dst/packages/daravel/lib/src/server/coordinator.dart" || { echo "p1ms sed missed" >> "$OUT/loads.txt"; exit 1; }
  fi
  cd "$dst" && "$DART" pub get > "$OUT/pubget-$name.txt" 2>&1 || exit 1
  cd "$dst/bench" && "$DART" build cli -t bin/coordinator_ceiling.dart -o build/ceiling > "$OUT/build-$name.txt" 2>&1 || { echo "build $name failed" >> "$OUT/loads.txt"; exit 1; }
}
build pa
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
  run "pa_overflow_$round" "$(bin pa)" --sections=saturation --window=16 --buffer=16
  run "p1ms_overflow_$round" "$(bin p1ms)" --sections=saturation --window=16 --buffer=16
done
for round in 1 2 3; do
  run "pa_starved_$round" "$(bin pa)" --sections=starved --window=16
done
run "pa_saturation_1" "$(bin pa)" --sections=saturation --window=16
echo done >> "$OUT/loads.txt"
