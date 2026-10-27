#!/usr/bin/env bash
# The public benchmark: Daravel against Laravel on a machine that does
# nothing else, repeated, with a saturation curve and a second load
# generator, and every raw number kept.
#
#   bash bench/public.sh                       # Linux + Docker, ~1 hour on 8 cores
#   RUNS=1 DURATION=3 CURVE=16,64 bash bench/public.sh   # a quick dry run
#
# Writes bench/results/<date>-<host>/ (or OUT):
#
#   environment.txt     hardware, kernel, versions, commit, settings
#   runs/<n>/*.json     RUNS × bench/laravel/compare.sh at 64 connections
#   pgsql/<n>/*.json    RUNS × the database scenarios (PG_SCENARIOS) on PostgreSQL
#   overload/<n>/*.json RUNS × scenario 11 (Daravel under overload, with and
#                       without load shedding)
#   curve/*.json        CURVE_SCENARIOS at each of CURVE connections, WORKERS workers
#   oha/*.json          oha against Daravel and Octane (GET scenarios 1, 2, 4)
#   report.md           the tables (bin/public_report.dart)
#   summary.json        the same numbers as JSON
#
# Servers run on SERVER_CPUS and the load generators on CLIENT_CPUS (by
# default the first and the second half of the cores), so they never share
# a core. On a VM, prefer dedicated vCPUs: shared ones measure the
# neighbours. Settings: RUNS (5), DURATION (10 s per scenario), WORKERS (4),
# CURVE (16,64,256,1024), CURVE_SCENARIOS (1,2), DART_IMAGE (dart:stable),
# OHA_VERSION (1.16.0), PG_SCENARIOS (2,3,4,11; empty skips PostgreSQL),
# PG_IMAGE (postgres:17), OVERLOAD_CONNECTIONS (512), MAX_IN_FLIGHT (32),
# MAX_QUEUE_DELAY (50, ms), WORK (~/daravel-bench).
set -euo pipefail

RUNS=${RUNS:-5}
DURATION=${DURATION:-10}
WORKERS=${WORKERS:-4}
CURVE=${CURVE:-16,64,256,1024}
CURVE_SCENARIOS=${CURVE_SCENARIOS:-1,2}
DART_IMAGE=${DART_IMAGE:-dart:stable}
OHA_VERSION=${OHA_VERSION:-1.16.0}
PG_SCENARIOS=${PG_SCENARIOS-2,3,4,11}
PG_IMAGE=${PG_IMAGE:-postgres:17}
OVERLOAD_CONNECTIONS=${OVERLOAD_CONNECTIONS:-512}
MAX_IN_FLIGHT=${MAX_IN_FLIGHT:-32}
MAX_QUEUE_DELAY=${MAX_QUEUE_DELAY:-50}
WORK=${WORK:-$HOME/daravel-bench}
REPO=$(cd "$(dirname "$0")/.." && pwd)
CPUS=$(nproc)
HALF=$((CPUS / 2))
SERVER_CPUS=${SERVER_CPUS:-0-$((HALF - 1))}
CLIENT_CPUS=${CLIENT_CPUS:-$HALF-$((CPUS - 1))}
OUT=${OUT:-$REPO/bench/results/$(date -u +%Y-%m-%d)-$(hostname -s)}
PORT=18600

if [ "$CPUS" -lt 4 ]; then
  echo "public.sh needs at least 4 cores (server and load generator apart); this machine has $CPUS." >&2
  exit 1
fi
if [ -e "$OUT" ]; then
  echo "$OUT exists; remove it or set OUT." >&2
  exit 1
fi
mkdir -p "$OUT/runs" "$OUT/pgsql" "$OUT/overload" "$OUT/curve" "$OUT/oha" "$WORK/tools"
export DURATION WORKERS SERVER_CPUS CLIENT_CPUS WORK DART_IMAGE PG_IMAGE \
  OVERLOAD_CONNECTIONS MAX_IN_FLIGHT MAX_QUEUE_DELAY

# --- oha, pinned. The checksum is the one of the release asset on GitHub.
case "$(uname -m)" in
  x86_64) OHA_ASSET=oha-linux-amd64 ;;
  aarch64) OHA_ASSET=oha-linux-arm64 ;;
  *) echo "No oha build for $(uname -m)." >&2; exit 1 ;;
esac
if [ "$OHA_VERSION" = 1.16.0 ] && [ "$OHA_ASSET" = oha-linux-amd64 ]; then
  OHA_SHA256=${OHA_SHA256:-620bb9e16fb53eabc9a3fc45f88bdb41fefa3fee5c05e75892011ce320391716}
fi
OHA="$WORK/tools/oha-$OHA_VERSION"
if [ ! -x "$OHA" ]; then
  curl -fsSL -o "$OHA.part" \
    "https://github.com/hatoo/oha/releases/download/v$OHA_VERSION/$OHA_ASSET"
  if [ -n "${OHA_SHA256:-}" ]; then
    echo "$OHA_SHA256  $OHA.part" | sha256sum -c --quiet -
  else
    echo "warning: no OHA_SHA256 for $OHA_ASSET $OHA_VERSION; not verified." >&2
  fi
  chmod +x "$OHA.part"
  mv "$OHA.part" "$OHA"
fi

# --- What the numbers were measured on.
docker pull -q "$DART_IMAGE" >/dev/null
if [ -n "$PG_SCENARIOS" ]; then docker pull -q "$PG_IMAGE" >/dev/null; fi
docker build --network=host -q -t daravel-bench-laravel "$REPO/bench/laravel" >/dev/null
{
  echo "date:        $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "commit:      $(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)$(
    [ -n "$(git -C "$REPO" status --porcelain 2>/dev/null)" ] && echo ' (uncommitted changes)')"
  echo "daravel:     $(sed -n "s/^const String daravelVersion = '\(.*\)';/\1/p" \
    "$REPO/packages/daravel/lib/src/foundation/version.dart")"
  echo "cpu:         $(lscpu | sed -n 's/^Model name: *//p')"
  echo "cores:       $CPUS ($(lscpu | sed -n 's/^Thread(s) per core: *//p') threads per core)"
  echo "memory:      $(free -h | awk '/^Mem:/ {print $2}')"
  echo "virtualised: $(systemd-detect-virt 2>/dev/null || echo unknown)"
  echo "governor:    $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
  echo "kernel:      $(uname -sr)"
  echo "docker:      $(docker version --format '{{.Server.Version}}')"
  echo "dart:        $(docker run --rm "$DART_IMAGE" dart --version 2>&1 | head -1)" \
    "($(docker image inspect --format '{{index .RepoDigests 0}}' "$DART_IMAGE"))"
  docker run --rm --entrypoint sh daravel-bench-laravel -c '
    echo "php:         $(php -r "echo PHP_VERSION;") (opcache.enable=$(php -r "echo ini_get(\"opcache.enable\");"), opcache.jit=$(php -r "echo ini_get(\"opcache.jit\");"))"
    echo "frankenphp:  $(frankenphp version | head -1)"
    echo "laravel:     $(php artisan --version)"
    echo "octane:      $(composer show laravel/octane 2>/dev/null | sed -n "s/^versions *: *[*]* *//p")"'
  if [ -n "$PG_SCENARIOS" ]; then
    echo "postgres:    $(docker run --rm "$PG_IMAGE" postgres --version)" \
      "($(docker image inspect --format '{{index .RepoDigests 0}}' "$PG_IMAGE"))"
  fi
  echo "oha:         $("$OHA" --version) ($OHA_ASSET, sha256 $(sha256sum "$OHA" | cut -c1-16)…)"
  echo "settings:    RUNS=$RUNS DURATION=${DURATION}s WORKERS=$WORKERS CURVE=$CURVE" \
    "CURVE_SCENARIOS=$CURVE_SCENARIOS PG_SCENARIOS=$PG_SCENARIOS" \
    "OVERLOAD_CONNECTIONS=$OVERLOAD_CONNECTIONS MAX_IN_FLIGHT=$MAX_IN_FLIGHT" \
    "MAX_QUEUE_DELAY=${MAX_QUEUE_DELAY}ms"
  echo "cpus:        servers $SERVER_CPUS, load generators $CLIENT_CPUS"
  echo "load before: $(cut -d' ' -f1-3 /proc/loadavg)"
  echo "containers:  $(docker ps -q | wc -l) running before the run"
} | tee "$OUT/environment.txt"

# --- 1. Repeated runs: the median and spread of every scenario.
for run in $(seq 1 "$RUNS"); do
  echo "== Run $run of $RUNS"
  CONNECTIONS=64 bash "$REPO/bench/laravel/compare.sh"
  mkdir -p "$OUT/runs/$run"
  cp "$WORK/data"/*.json "$WORK/data/report.md" "$OUT/runs/$run/"
done

# --- 1b. The same on PostgreSQL, for the scenarios that query.
if [ -n "$PG_SCENARIOS" ]; then
  for run in $(seq 1 "$RUNS"); do
    echo "== PostgreSQL run $run of $RUNS"
    DB=pgsql SCENARIOS=$PG_SCENARIOS CONNECTIONS=64 bash "$REPO/bench/laravel/compare.sh"
    mkdir -p "$OUT/pgsql/$run"
    cp "$WORK/data"/*.json "$WORK/data/report.md" "$OUT/pgsql/$run/"
  done
fi

# --- 2. The saturation curve, WORKERS workers only.
echo "== Saturation curve ($CURVE connections)"
CONNECTIONS=$CURVE WORKER_COUNTS=$WORKERS SCENARIOS=$CURVE_SCENARIOS \
  bash "$REPO/bench/laravel/compare.sh"
cp "$WORK/data"/*.json "$OUT/curve/"

# --- 3. oha against the same servers. The last compare.sh left the AOT
# build and the seeded database in $WORK.
wait_up() {
  for _ in $(seq 1 600); do
    if curl -fs -o /dev/null "http://127.0.0.1:$PORT/up"; then return 0; fi
    sleep 0.2
  done
  echo "Nothing answered /up on port $PORT." >&2
  return 1
}
oha_all() { # server
  # Same keep-alive connections and duration as the harness, after a warm-up.
  # -w: requests in flight at the deadline finish instead of counting as
  # errors, as the harness does.
  for scenario in 1-ping:/ping 2-show-json-query:/api/users/42 4-eager-loading:/api/posts; do
    taskset -c "$CLIENT_CPUS" "$OHA" -z 2s -c 64 -w --no-tui --output-format quiet \
      "http://127.0.0.1:$PORT${scenario#*:}"
    taskset -c "$CLIENT_CPUS" "$OHA" -z "${DURATION}s" -c 64 -w --no-tui --output-format json \
      "http://127.0.0.1:$PORT${scenario#*:}" \
      >"$OUT/oha/$1_w${WORKERS}_c64_${scenario%%:*}.json"
  done
}
stop() { docker rm -f "$1" >/dev/null 2>&1 || true; }
trap 'stop daravel-bench-serve; stop daravel-bench-laravel-run' EXIT

echo "== oha $OHA_VERSION: Daravel"
stop daravel-bench-serve
docker run -d --name daravel-bench-serve --network host \
  -v "$WORK/src:/src" -v "$WORK/data:/data" -v "$WORK/pub-cache:/root/.pub-cache" \
  -w /src/bench "$DART_IMAGE" sh -c "exec dart run bin/bench.dart --serve --skip-build \
    --database=/data/bench.sqlite --server-cpus=$SERVER_CPUS --isolates=$WORKERS --port=$PORT" \
  >/dev/null
wait_up
oha_all daravel
stop daravel-bench-serve

echo "== oha $OHA_VERSION: Laravel Octane"
stop daravel-bench-laravel-run
docker run -d --name daravel-bench-laravel-run --network host \
  --cpuset-cpus="$SERVER_CPUS" -v "$WORK/data:/data" \
  -e MODE=octane -e WORKERS="$WORKERS" -e PORT=$PORT daravel-bench-laravel >/dev/null
wait_up
oha_all laravel-octane
stop daravel-bench-laravel-run

# --- 3b. Scenario 11: Daravel flooded with OVERLOAD_CONNECTIONS, without a
# limit, with HTTP_MAX_IN_FLIGHT, and with HTTP_MAX_QUEUE_DELAY added (Laravel
# has no equivalent to compare). Reuses the AOT build and the seeded SQLite
# database the last compare.sh left in $WORK.
for run in $(seq 1 "$RUNS"); do
  echo "== Overload run $run of $RUNS"
  docker run --rm --network host \
    -v "$WORK/src:/src" -v "$WORK/data:/data" -v "$WORK/pub-cache:/root/.pub-cache" \
    -w /src/bench "$DART_IMAGE" sh -c "taskset -c $CLIENT_CPUS dart run bin/bench.dart \
      --skip-build --database=/data/bench.sqlite --server-cpus=$SERVER_CPUS \
      --isolates=1,$WORKERS --duration=$DURATION --scenarios=11 \
      --overload-connections=$OVERLOAD_CONNECTIONS --max-in-flight=$MAX_IN_FLIGHT \
      --max-queue-delay=$MAX_QUEUE_DELAY --out=/data/overload.json"
  mkdir -p "$OUT/overload/$run"
  cp "$WORK/data/overload.json" "$OUT/overload/$run/daravel.json"
done

# --- 4. The report.
report() {
  docker run --rm -v "$WORK/src:/src" -v "$WORK/pub-cache:/root/.pub-cache" \
    -v "$OUT:/out:ro" -w /src/bench "$DART_IMAGE" dart run bin/public_report.dart /out "$@"
}
report >"$OUT/report.md"
report --json >"$OUT/summary.json"
cat "$OUT/report.md"
echo "Results: $OUT"
