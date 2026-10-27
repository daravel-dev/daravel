#!/usr/bin/env bash
# Laravel 12 and Daravel on one Redis (Linux and Docker): a cache lock taken
# by either is refused to the other, with the same owner, a number in the
# cache counts up from both sides, with REDIS_SERIALIZER=php each reads the
# other's cached arrays, tagged entries are shared and flushed from either
# side, and Redis::throttle counts both.
#
#   bash bench/interop/redis.sh
set -uo pipefail

WORK=${WORK:-$HOME/daravel-bench}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
PORT=16390
SHARED=(-e REDIS_HOST=127.0.0.1 -e REDIS_PORT=$PORT -e CACHE_STORE=redis
  -e CACHE_PREFIX=shared-cache- -e REDIS_PREFIX=shared-database-
  -e REDIS_SERIALIZER=php)

docker run --rm -v "$WORK:/w" dart:stable rm -rf /w/src >/dev/null
mkdir -p "$WORK/src" "$WORK/pub-cache"
tar -C "$REPO" --exclude=.git --exclude=.dart_tool --exclude=build \
  --exclude='docs/reviews' --exclude='docs/external-reviews' -cf - . |
  tar -C "$WORK/src" -xf -

docker build --network=host -q -t daravel-bench-laravel "$REPO/bench/laravel" >/dev/null
docker build --network=host -q -t daravel-interop-laravel-redis - >/dev/null <<'DOCKER'
FROM daravel-bench-laravel
RUN composer require predis/predis --no-interaction -q
DOCKER

docker rm -f redis-interop >/dev/null 2>&1
docker run -d --name redis-interop --network host redis:7 --port $PORT >/dev/null
trap 'docker rm -f redis-interop >/dev/null 2>&1' EXIT
sleep 1

laravel() { # php code
  docker run --rm --network host --entrypoint php "${SHARED[@]}" -e REDIS_CLIENT=predis \
    daravel-interop-laravel-redis artisan tinker --execute="$1" 2>&1 | grep -v '^$'
}
daravel() { # step
  docker run --rm --network host -v "$WORK/src:/src" -v "$WORK/pub-cache:/root/.pub-cache" \
    -w /src/bench "${SHARED[@]}" dart:stable \
    sh -c "dart pub get >/dev/null 2>&1; dart run bin/redis_interop.dart $1" 2>&1 | tail -1
}

status=0
check() { # name expected actual
  if [[ "$3" == *"$2"* ]]; then echo "PASS $1"; else echo "FAIL $1: expected [$2] in [$3]"; status=1; fi
}

# The first Daravel run compiles; done before a lock with a 30s lifetime.
daravel get >/dev/null

echo "== Laravel takes the lock, Daravel is refused"
owner=$(laravel '$l = Cache::lock("report", 30); $l->get(); echo $l->owner();' | tail -1)
out=$(daravel lock)
check "Daravel refused" "acquired=false" "$out"
check "same owner as Laravel" "owner=$owner" "$out"
laravel 'Cache::restoreLock("report", "'"$owner"'")->release();' >/dev/null

echo "== Daravel takes the lock, Laravel is refused"
out=$(daravel lock)
check "Daravel acquired" "acquired=true" "$out"
check "Laravel refused" "refused" "$(laravel 'echo Cache::lock("report", 30)->get() ? "got" : "refused";' | tail -1)"
daravel release >/dev/null

echo "== A number counts up from both sides"
laravel 'Cache::put("visits", 41, 60); Cache::increment("visits");' >/dev/null
check "Daravel reads Laravel's number" "visits=42" "$(daravel get)"
check "Daravel increments it" "visits=43" "$(daravel increment)"
check "Laravel reads Daravel's number" "43" "$(laravel 'echo Cache::get("visits");' | tail -1)"

echo "== Cached arrays, both ways (REDIS_SERIALIZER=php)"
laravel 'Cache::put("profile", ["name" => "Ana", "roles" => ["admin", "editor"], "active" => true, "score" => 1.5], 60);' >/dev/null
check "Daravel reads Laravel's array" '{"name":"Ana","roles":["admin","editor"],"active":true,"score":1.5}' "$(daravel profile)"
daravel put-profile >/dev/null
check "Laravel reads Daravel's array" '{"name":"Bo","tags":["x"],"none":null}' "$(laravel 'echo json_encode(Cache::get("profile"));' | tail -1)"

echo "== Tagged entries, both ways"
laravel 'Cache::tags(["people", "artists"])->put("John", "x", 60);' >/dev/null
check "Daravel reads Laravel's tagged entry" "John=x" "$(daravel tags-get)"
daravel tags-put >/dev/null
check "Laravel reads Daravel's tagged entry" "y" "$(laravel 'echo Cache::tags(["people"])->get("Anne");' | tail -1)"
daravel tags-flush >/dev/null
check "Daravel's flush reaches Laravel" "NULL" "$(laravel 'var_export(Cache::tags(["people", "artists"])->get("John"));' | tail -1)"
laravel 'Cache::tags(["people"])->flush();' >/dev/null
check "Laravel's flush reaches Daravel" "Anne=null" "$(daravel tags-get)"

echo "== One throttle for both"
throttle='echo \Illuminate\Support\Facades\Redis::throttle("reports")->allow(2)->every(60)->block(0)->then(fn () => "ran", fn () => "refused");'
check "Laravel runs (1 of 2)" "ran" "$(laravel "$throttle" | tail -1)"
check "Daravel runs (2 of 2)" "throttle=ran" "$(daravel throttle)"
check "Laravel is refused" "refused" "$(laravel "$throttle" | tail -1)"
check "Daravel is refused" "throttle=refused" "$(daravel throttle)"

[ $status -eq 0 ] && echo "All Redis interop checks passed." || echo "Some Redis interop checks failed."
exit $status
