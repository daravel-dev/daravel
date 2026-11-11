#!/usr/bin/env bash
# publish x 1 and x 8 alone, 10 rounds alternating (ACK 258 §2 b, ACK 264
# §3.2): main before #239 (bc30f4f7, K1b's bench file adapted to its API by
# one sed) against main after #239 (ee408f3b, K1 + K1b). 20 s per point,
# each run started once the 1-minute load is below 2. Input to K2.
set -uo pipefail
DART="$HOME/.local/share/dart-sdks/3.13.4/bin/dart"
export PUB_CACHE="$HOME/.pub-cache"
SRC=${SRC:?set SRC}
STAMP=$(date +%Y%m%d-%H%M%S)
WORK="$HOME/publish10-$STAMP"
OUT="$SRC/publish10-$STAMP"
mkdir -p "$WORK" "$OUT"
echo "work=$WORK" > "$OUT/loads.txt"
build() {
  local name=$1 tarball=$2 dst="$WORK/$1"
  mkdir -p "$dst" && tar -xf "$SRC/$tarball" -C "$dst"
  if [ "$name" = before ]; then
    sed -e '/bulkWindow: job.window,/d' -e '/bulkBuffer: job.buffer,/d' \
      -e 's/RemoteCoordinatorChannel.defaultBulkWindow/16/g' \
      -e 's/RemoteCoordinatorChannel.defaultBulkBuffer/1024/g' \
      "$WORK/after/bench/bin/coordinator_ceiling.dart" > "$dst/bench/bin/coordinator_ceiling.dart"
  fi
  cd "$dst" && "$DART" pub get > "$OUT/pubget-$name.txt" 2>&1 || exit 1
  cd "$dst/bench" && "$DART" build cli -t bin/coordinator_ceiling.dart -o build/ceiling > "$OUT/build-$name.txt" 2>&1 || { echo "build $name failed" >> "$OUT/loads.txt"; exit 1; }
}
build after after239.tar
build before before239.tar
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
  "$binary" --duration=20 --clients=1,8 --json "$@" > "$OUT/$name.json" 2> "$OUT/$name.err"
  echo "$name exit=$?" >> "$OUT/loads.txt"
}
for round in $(seq 1 10); do
  if [ $((round % 2)) = 1 ]; then
    run "before_ceiling-publish_$round" "$(bin before)" --sections=ceiling --ops=publish
    run "after_ceiling-publish_$round" "$(bin after)" --sections=ceiling --ops=publish --window=16
  else
    run "after_ceiling-publish_$round" "$(bin after)" --sections=ceiling --ops=publish --window=16
    run "before_ceiling-publish_$round" "$(bin before)" --sections=ceiling --ops=publish
  fi
done
echo done >> "$OUT/loads.txt"
