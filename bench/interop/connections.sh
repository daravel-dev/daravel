#!/usr/bin/env bash
# Idle Pusher connections against an AOT build of Daravel: memory per
# connection and the time one event takes to reach all of them.
#
#   bash bench/interop/connections.sh                  # 10 000 connections, 1 isolate
#   COUNT=20000 ISOLATES=4 bash bench/interop/connections.sh
set -uo pipefail

COUNT=${COUNT:-10000}
ISOLATES=${ISOLATES:-1}
WORK=${WORK:-$HOME/daravel-bench}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PORT=18750

docker run --rm -v "$WORK:/w" dart:stable rm -rf /w/src /w/build-interop >/dev/null
mkdir -p "$WORK/src" "$WORK/pub-cache"
tar -C "$REPO" --exclude=.git --exclude=.dart_tool --exclude=build \
  --exclude='docs/reviews' --exclude='docs/external-reviews' -cf - . |
  tar -C "$WORK/src" -xf -

echo "== Building the interop server AOT"
docker run --rm -v "$WORK/src:/src" -v "$WORK/pub-cache:/root/.pub-cache" -w /src/bench \
  dart:stable sh -c 'dart pub get >/dev/null 2>&1 &&
    dart build cli -t bin/interop_server.dart -o /src/build-interop >/dev/null 2>&1 &&
    ls /src/build-interop/bundle/bin/interop_server' >/dev/null || { echo "build failed"; exit 1; }

docker rm -f daravel-connections >/dev/null 2>&1
docker run -d --name daravel-connections --network host --ulimit nofile=200000:200000 \
  -v "$WORK/src/build-interop/bundle:/app" -w /tmp -e APP_ENV=production -e APP_DEBUG=false \
  -e APP_HOST=127.0.0.1 -e APP_PORT=$PORT -e APP_ISOLATES="$ISOLATES" \
  -e APP_KEY="base64:$(head -c 32 /dev/urandom | base64)" -e DB_DATABASE=/tmp/connections.sqlite \
  -e LOG_LEVEL=error -e REVERB_APP_ID=app1 -e REVERB_APP_KEY=key1 -e REVERB_APP_SECRET=secret1 \
  debian:bookworm-slim /app/bin/interop_server >/dev/null
trap 'docker rm -f daravel-connections >/dev/null 2>&1' EXIT
for _ in $(seq 1 60); do curl -sf "http://127.0.0.1:$PORT/up" >/dev/null && break; sleep 1; done

rss() { docker exec daravel-connections sh -c 'grep VmRSS /proc/1/status' | tr -s ' ' | cut -d' ' -f2; }
idle=$(rss)
echo "idle RSS: ${idle} kB (isolates: $ISOLATES)"

docker run --rm --network host --ulimit nofile=200000:200000 -v "$WORK/src:/src" \
  -v "$WORK/pub-cache:/root/.pub-cache" -w /src/bench dart:stable \
  sh -c "dart run bin/connections.dart --url=ws://127.0.0.1:$PORT/app/key1 --count=$COUNT \
    --trigger=http://127.0.0.1:$PORT/api/publish --hold=15" 2>&1 |
  while read -r line; do
    echo "$line"
    case "$line" in
      *SUBSCRIBED*)
        sleep 10
        loaded=$(rss)
        echo "RSS with $COUNT connections: ${loaded} kB (+$((loaded - idle)) kB, $(((loaded - idle) * 1024 / COUNT)) bytes per connection)"
        ;;
    esac
  done
