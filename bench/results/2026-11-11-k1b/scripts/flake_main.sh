#!/usr/bin/env bash
# supervisor_test "process-scope state" 30x on main, under 16 CPU burners,
# as flake30.sh did for K1 and K1b. The burners' PIDs go to burners.pid so
# they can be killed even when this script is stopped from outside (its
# trap does not run then); flake_cleanup.sh kills them.
OUT=$SCRATCH/flake_main
mkdir -p "$OUT"
: > "$OUT/burners.pid"
for i in $(seq 1 16); do
  ( while :; do :; done ) &
  echo $! >> "$OUT/burners.pid"
done
cleanup() { xargs -r kill < "$OUT/burners.pid" 2>/dev/null; }
trap cleanup EXIT
cd $WORKTREE/packages/daravel || exit 1
for i in $(seq 1 30); do
  fvm dart test test/server/supervisor_test.dart --name "process-scope state" \
    > "$OUT/main-$i.txt" 2>&1
  echo "main $i exit=$?" >> "$OUT/summary.txt"
done
echo done >> "$OUT/summary.txt"
