#!/usr/bin/env bash
# Daravel's Pusher protocol against the real clients and servers (Linux and
# Docker; network access for npm and Composer):
#
#   bash bench/interop/run.sh
#   ISOLATES=4 bash bench/interop/run.sh   # Daravel with four worker isolates
#
# A. laravel-echo and pusher-js (npm) against Daravel: public, private
#    (/broadcasting/auth), toOthers, whispers, presence, notifications and
#    a refused authorization.
# B. Laravel 12 with BROADCAST_CONNECTION=reverb (pusher-php-server)
#    broadcasts through Daravel and reads its channels API.
# C. Daravel with BROADCAST_CONNECTION=reverb broadcasts through Laravel
#    Reverb, and Echo, connected to Reverb, receives it.
#
# Laravel comes from bench/laravel/Dockerfile, plus pusher/pusher-php-server
# and laravel/reverb.
set -uo pipefail

WORK=${WORK:-$HOME/daravel-bench}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
HERE="$REPO/bench/interop"
KEYS=(-e REVERB_APP_ID=app1 -e REVERB_APP_KEY=key1 -e REVERB_APP_SECRET=secret1
  -e REVERB_ENCRYPTION_MASTER_KEY_BASE64=KioqKioqKioqKioqKioqKioqKioqKioqKioqKioqKio=)

# A copy of the working tree, so the container's `pub get` never touches
# the checkout's .dart_tool; its files are root's, so a container removes it.
docker run --rm -v "$WORK:/w" dart:stable rm -rf /w/src >/dev/null
mkdir -p "$WORK/src" "$WORK/pub-cache" "$WORK/npm"
tar -C "$REPO" --exclude=.git --exclude=.dart_tool --exclude=build \
  --exclude='docs/reviews' --exclude='docs/external-reviews' -cf - . |
  tar -C "$WORK/src" -xf -

docker build --network=host -q -t daravel-bench-laravel "$REPO/bench/laravel" >/dev/null
docker build --network=host -q -t daravel-interop-laravel - >/dev/null <<'DOCKER'
FROM daravel-bench-laravel
RUN composer require pusher/pusher-php-server laravel/reverb --no-interaction -q
DOCKER

daravel() { # name port extra-env...
  local name=$1 port=$2
  shift 2
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --name "$name" --network host -v "$WORK/src:/src" \
    -v "$WORK/pub-cache:/root/.pub-cache" -w /src/bench -e APP_ENV=local \
    -e APP_HOST=127.0.0.1 -e APP_PORT="$port" -e DB_DATABASE=/tmp/interop.sqlite \
    -e APP_ISOLATES="${ISOLATES:-1}" \
    -e APP_KEY="base64:$(head -c 32 /dev/zero | base64)" -e LOG_LEVEL=warning \
    "${KEYS[@]}" "$@" dart:stable \
    sh -c 'dart pub get >/dev/null 2>&1; dart run bin/interop_server.dart' >/dev/null
  for _ in $(seq 1 120); do
    curl -sf "http://127.0.0.1:$port/up" >/dev/null && return 0
    sleep 1
  done
  echo "$name did not start"
  docker logs "$name" | tail -20
  return 1
}

echo_client() { # env... (runs echo_test.mjs)
  docker run --rm --network host -v "$WORK/npm:/work" -v "$HERE:/test:ro" -w /work \
    "$@" node:22-alpine sh -c '
      [ -d node_modules/laravel-echo ] || npm install --silent laravel-echo pusher-js >/dev/null 2>&1
      cp /test/echo_test.mjs . && node echo_test.mjs'
}

listener() { # port event output: waits until subscribed
  echo_client -e PORT="$1" -e KEY=key1 -e MODE=listen -e EVENT="$2" >"$3" 2>&1 &
  for _ in $(seq 1 120); do
    grep -q READY "$3" && return 0
    sleep 1
  done
  cat "$3"
  return 1
}

cleanup() { docker rm -f daravel-interop daravel-to-reverb reverb-interop >/dev/null 2>&1; }
trap cleanup EXIT
status=0

echo "== A: Laravel Echo and pusher-js against Daravel"
daravel daravel-interop 18700 || exit 1
echo_client -e PORT=18700 -e KEY=key1 || status=1

echo "== B: Laravel broadcasts through Daravel"
listener 18700 .FromLaravel "$WORK/b.out" || exit 1
docker run --rm --network host --entrypoint php "${KEYS[@]}" -e BROADCAST_CONNECTION=reverb \
  -e REVERB_HOST=127.0.0.1 -e REVERB_PORT=18700 -e REVERB_SCHEME=http daravel-interop-laravel \
  artisan tinker --execute='
    $pusher = Broadcast::connection("reverb")->getPusher();
    echo "channels: ", json_encode($pusher->getChannels()), "\n";
    echo "news: ", json_encode($pusher->getChannelInfo("news", ["info" => "subscription_count"])), "\n";
    Broadcast::connection("reverb")->broadcast(["news"], "FromLaravel", ["from" => "Laravel ".app()->version()]);'
wait
cat "$WORK/b.out"
grep -q "1 passed, 0 failed" "$WORK/b.out" || status=1

echo "== C: Daravel broadcasts through Laravel Reverb"
docker run -d --name reverb-interop --network host --entrypoint php "${KEYS[@]}" \
  daravel-interop-laravel artisan reverb:start --host=127.0.0.1 --port=18800 >/dev/null
daravel daravel-to-reverb 18701 -e BROADCAST_CONNECTION=reverb -e REVERB_HOST=127.0.0.1 \
  -e REVERB_PORT=18800 -e REVERB_SCHEME=http || exit 1
listener 18800 .published "$WORK/c.out" || exit 1
curl -s -o /dev/null -X POST http://127.0.0.1:18701/api/publish
wait
cat "$WORK/c.out"
grep -q "1 passed, 0 failed" "$WORK/c.out" || status=1

[ $status -eq 0 ] && echo "All interop scenarios passed." || echo "Some interop scenarios failed."
exit $status
