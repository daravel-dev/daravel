#!/usr/bin/env bash
# K1b measurement (Blueprint #141 §6.4): healthy ceiling 1/8/16 senders and
# saturation under a 16-isolate publish flood, main against K1b with bulk
# windows 8, 16 and 32, three rounds alternating. Windows stays idle.
set -euo pipefail
DART="$HOME/.local/share/dart-sdks/3.13.4/bin/dart"
export PUB_CACHE="$HOME/.pub-cache"
SRC=$SCRATCH/k1b_bench
STAMP=$(date +%Y%m%d-%H%M%S)
WORK="$HOME/k1b-bench-$STAMP"
OUT="$SRC/results-$STAMP"
mkdir -p "$WORK" "$OUT"
echo "work=$WORK out=$OUT" | tee "$OUT/loads.txt"

build() {
  local name=$1
  local dst="$WORK/$name"
  mkdir -p "$dst"
  tar -xf "$SRC/$name.tar" -C "$dst"
  cd "$dst"
  [ "$(pwd)" = "$dst" ] || { echo "not in $dst"; exit 1; }
  "$DART" pub get > "$OUT/pubget-$name.txt" 2>&1
  cd "$dst/bench"
  [ "$(pwd)" = "$dst/bench" ] || { echo "not in $dst/bench"; exit 1; }
  "$DART" build cli -t bin/coordinator_ceiling.dart -o build/ceiling > "$OUT/build-$name.txt" 2>&1
  ls "$dst/bench/build/ceiling/bundle/bin/coordinator_ceiling"
}

build main
build k1b

run() {
  local name=$1 binary=$2
  shift 2
  echo "$name load: $(cut -d' ' -f1-3 /proc/loadavg)" >> "$OUT/loads.txt"
  set +e
  "$binary" --duration=5 --clients=1,8,16 --json "$@" > "$OUT/$name.json" 2> "$OUT/$name.err"
  echo "$name exit=$?" >> "$OUT/loads.txt"
  set -e
}

MAIN="$WORK/main/bench/build/ceiling/bundle/bin/coordinator_ceiling"
K1B="$WORK/k1b/bench/build/ceiling/bundle/bin/coordinator_ceiling"
for round in 1 2 3; do
  run "main_$round" "$MAIN"
  for w in 8 16 32; do
    run "k1b-w${w}_$round" "$K1B" "--window=$w"
  done
done
echo done >> "$OUT/loads.txt"
