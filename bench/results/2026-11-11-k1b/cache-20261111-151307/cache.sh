#!/usr/bin/env bash
# K1b cache x 1 alone (ACK 247 §1): main (d4f973fe, K1b bench file adapted
# to main API) against K1b (4d84d3e1, lib = 0de7d0d3) W 16: cache get, one
# sender, 20 s, ten rounds, the order alternating (main first in odd rounds).
# Each run starts once the 1-minute load is below 2.
set -uo pipefail
DART="$HOME/.local/share/dart-sdks/3.13.4/bin/dart"
export PUB_CACHE="$HOME/.pub-cache"
SRC=${SRC:?set SRC}
STAMP=$(date +%Y%m%d-%H%M%S)
WORK="$HOME/k1b-cache-$STAMP"
OUT="$SRC/cache-$STAMP"
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
build k1b k1b7.tar
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
  "$binary" --duration=20 --json "$@" > "$OUT/$name.json" 2> "$OUT/$name.err"
  echo "$name exit=$?" >> "$OUT/loads.txt"
}

for round in $(seq 1 10); do
  if [ $((round % 2)) = 1 ]; then
    run "main_ceiling-cache_$round" "$MAIN" --sections=ceiling --ops=cache --clients=1
    run "k1b_ceiling-cache_$round" "$K1B" --sections=ceiling --ops=cache --clients=1 --window=16
  else
    run "k1b_ceiling-cache_$round" "$K1B" --sections=ceiling --ops=cache --clients=1 --window=16
    run "main_ceiling-cache_$round" "$MAIN" --sections=ceiling --ops=cache --clients=1
  fi
done
echo done >> "$OUT/loads.txt"
