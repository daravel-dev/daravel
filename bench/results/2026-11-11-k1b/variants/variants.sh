#!/usr/bin/env bash
# K1b publish refill variants (ACK 240 §1): main (d4f973fe, K1b's bench file
# adapted to main's API) against K1b at the final code (k1b3.tar) and two
# refill variants built from it by one sed each:
#   a: credit back -> send at once when at most one call waits
#      (batches only when a queue forms);
#   b: refill once a quarter of the window is free (W/4) instead of half.
# Only publish x 1/8/16 (20 s per point) and saturation, three rounds, the
# variant order rotated, each run started once the 1-minute load is < 2.
set -uo pipefail
DART="$HOME/.local/share/dart-sdks/3.13.4/bin/dart"
export PUB_CACHE="$HOME/.pub-cache"
SRC=${SRC:?set SRC to the folder holding the tarballs}
STAMP=$(date +%Y%m%d-%H%M%S)
WORK="$HOME/k1b-variants-$STAMP"
OUT="$SRC/variants-$STAMP"
mkdir -p "$WORK" "$OUT"
echo "work=$WORK" > "$OUT/loads.txt"
CO=packages/daravel/lib/src/server/coordinator.dart

build() {
  local name=$1 tarball=$2
  local dst="$WORK/$name"
  mkdir -p "$dst"
  tar -xf "$SRC/$tarball" -C "$dst"
  case "$name" in
    main)
      sed -e '/bulkWindow: job.window,/d' -e '/bulkBuffer: job.buffer,/d' \
        -e 's/RemoteCoordinatorChannel.defaultBulkWindow/16/g' \
        -e 's/RemoteCoordinatorChannel.defaultBulkBuffer/1024/g' \
        "$SRC/ceiling_for_main.dart" > "$dst/bench/bin/coordinator_ceiling.dart" ;;
    a)
      sed -i 's/if (_bulkInFlight == 0 || bulkWindow - _bulkInFlight >= _refillAt) {/if (_bulkInFlight == 0 || _bulkWaiting.length <= 1 || bulkWindow - _bulkInFlight >= _refillAt) {/' "$dst/$CO"
      grep -q '_bulkWaiting.length <= 1 ||' "$dst/$CO" || { echo "sed a missed" >> "$OUT/loads.txt"; exit 1; } ;;
    b)
      sed -i 's/int get _refillAt => bulkWindow < 2 ? 1 : bulkWindow ~\/ 2;/int get _refillAt => bulkWindow < 4 ? 1 : bulkWindow ~\/ 4;/' "$dst/$CO"
      grep -q 'bulkWindow ~/ 4;' "$dst/$CO" || { echo "sed b missed" >> "$OUT/loads.txt"; exit 1; } ;;
  esac
  cd "$dst" && [ "$(pwd)" = "$dst" ] || exit 1
  "$DART" pub get > "$OUT/pubget-$name.txt" 2>&1 || exit 1
  cd "$dst/bench" && [ "$(pwd)" = "$dst/bench" ] || exit 1
  "$DART" build cli -t bin/coordinator_ceiling.dart -o build/ceiling > "$OUT/build-$name.txt" 2>&1 || {
    echo "build $name failed" >> "$OUT/loads.txt"; exit 1; }
}
build main main2.tar
build k1b k1b3.tar
build a k1b3.tar
build b k1b3.tar
bin() { echo "$WORK/$1/bench/build/ceiling/bundle/bin/coordinator_ceiling"; }

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
window() { [ "$1" = main ] || echo --window=16; }

VARIANTS=(main k1b a b)
for round in 1 2 3; do
  shift_by=$(( (round - 1) % 4 ))
  order=("${VARIANTS[@]:$shift_by}" "${VARIANTS[@]:0:$shift_by}")
  for v in "${order[@]}"; do
    run "${v}_ceiling-publish_$round" "$(bin "$v")" --sections=ceiling --ops=publish $(window "$v")
  done
  for v in "${order[@]}"; do
    run "${v}_saturation_$round" "$(bin "$v")" --sections=saturation $(window "$v")
  done
done
echo done >> "$OUT/loads.txt"
