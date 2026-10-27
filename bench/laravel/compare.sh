#!/usr/bin/env bash
# Daravel vs Laravel on the same machine, database and load generator.
#
#   bash bench/laravel/compare.sh            # from the repository root, Linux + Docker
#   SCENARIOS=6 bash bench/laravel/compare.sh  # only login
#   CONNECTIONS=16,64,256 WORKER_COUNTS=4 bash bench/laravel/compare.sh
#                                    # a saturation curve, 4 workers only
#
# Every server runs pinned to SERVER_CPUS and the load generator to
# CLIENT_CPUS, so they never share a core. Daravel runs from an AOT build in
# the dart image; Laravel runs in bench/laravel/Dockerfile (Laravel 12, PHP
# 8.4, OPcache) as Octane on FrankenPHP and as classic FrankenPHP (one
# bootstrap per request, like php-fpm). All use one SQLite database, seeded
# by Daravel, whose bcrypt hashes Laravel verifies as they are.
set -euo pipefail

DURATION=${DURATION:-10}
WORKERS=${WORKERS:-4}
# Worker counts measured for Daravel and Octane; classic runs WORKERS.
WORKER_COUNTS=${WORKER_COUNTS:-1,$WORKERS}
CONNECTIONS=${CONNECTIONS:-64}
DART_IMAGE=${DART_IMAGE:-dart:stable}
SCENARIOS=${SCENARIOS:-1,2,3,4,5,6}
SERVER_CPUS=${SERVER_CPUS:-0-3}
CLIENT_CPUS=${CLIENT_CPUS:-4-11}
WORK=${WORK:-$HOME/daravel-bench}
PORT=18600
REPO=$(cd "$(dirname "$0")/../.." && pwd)

mkdir -p "$WORK/data" "$WORK/pub-cache"
# The containers run as root, so their files are removed by one too.
docker run --rm -v "$WORK:/w" "$DART_IMAGE" rm -rf /w/src /w/data >/dev/null
mkdir -p "$WORK/data"
mkdir -p "$WORK/src"
# A copy of the working tree, so the container's `pub get` never touches the
# checkout's .dart_tool.
tar -C "$REPO" --exclude=.git --exclude=.dart_tool --exclude=build \
  --exclude='docs/reviews' --exclude='docs/external-reviews' \
  --exclude='bench/results' -cf - . |
  tar -C "$WORK/src" -xf -

docker build --network=host -q -t daravel-bench-laravel "$REPO/bench/laravel" >/dev/null

dart_run() {
  docker run --rm --network host \
    -v "$WORK/src:/src" -v "$WORK/data:/data" -v "$WORK/pub-cache:/root/.pub-cache" \
    -w /src/bench "$DART_IMAGE" sh -c "$1"
}

echo "== Daravel (AOT, isolates $WORKER_COUNTS, cores $SERVER_CPUS)"
dart_run "dart pub get >/dev/null && taskset -c $CLIENT_CPUS dart run bin/bench.dart \
  --database=/data/bench.sqlite --server-cpus=$SERVER_CPUS --isolates=$WORKER_COUNTS \
  --duration=$DURATION --scenarios=$SCENARIOS --connections=$CONNECTIONS \
  --out=/data/daravel.json"

laravel() { # name mode workers
  docker rm -f daravel-bench-laravel-run >/dev/null 2>&1 || true
  docker run -d --name daravel-bench-laravel-run --network host \
    --cpuset-cpus="$SERVER_CPUS" -v "$WORK/data:/data" \
    -e MODE="$2" -e WORKERS="$3" -e PORT=$PORT daravel-bench-laravel >/dev/null
  dart_run "taskset -c $CLIENT_CPUS dart run bin/bench.dart --external=$1:$PORT \
    --isolates=$3 --duration=$DURATION --scenarios=$SCENARIOS \
    --connections=$CONNECTIONS --out=/data/$1-$3.json"
  docker rm -f daravel-bench-laravel-run >/dev/null
}

echo "== Laravel Octane (FrankenPHP worker mode)"
for workers in ${WORKER_COUNTS//,/ }; do
  laravel laravel-octane octane "$workers"
done
echo "== Laravel classic (FrankenPHP, no worker mode)"
laravel laravel-classic classic "$WORKERS"

dart_run "dart run bin/laravel_report.dart /data" | tee "$WORK/data/report.md"
echo "Results: $WORK/data"
