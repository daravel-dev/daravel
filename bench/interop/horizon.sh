#!/usr/bin/env bash
# Laravel Horizon (Laravel 12, laravel/horizon) and Daravel's Horizon on one
# Redis and one PostgreSQL (Linux and Docker), with the same REDIS_PREFIX:
# Laravel Horizon works the `default` queue, `dartisan horizon` works
# `daravel`. Twice: Laravel first, then Daravel; and the other way round.
#
#   bash bench/interop/horizon.sh
#
# Checks, each PASS or FAIL in the table at the end (exit 1 on any FAIL):
#  a/h  each side ran exactly its own 50 jobs, by its own workers; no
#       failed_jobs on either side
#  b    Daravel running, and its own commands (horizon:clear, horizon:snapshot,
#       horizon:terminate, queue:clear) leave Laravel Horizon's keys
#       (`laravel_horizon:*`) as Laravel left them (names and types)
#  c    every key of Daravel's Horizon store has a TTL, but `monitored`
#  d    both dashboards answer, each with its own jobs only
#  e    Laravel Horizon starting, stopping, and horizon:clear, horizon:purge,
#       horizon:terminate, horizon:snapshot, horizon:clear-metrics and
#       queue:clear leave Daravel's keys as Daravel left them
#  g    neither side sends FLUSHDB/FLUSHALL (grep of both sources)
#
# Laravel Horizon's key names are read from laravel/horizon as installed (the
# version is printed): its prefix is `horizon.prefix`, by default
# `Str::slug(env('APP_NAME', 'laravel'), '_').'_horizon:'` (config/horizon.php),
# applied to its own `horizon` connection in place of REDIS_PREFIX
# (Horizon::configureStandaloneConnection). horizon:clear-metrics SCANs
# `<prefix>queue:*`, `<prefix>job:*` and `<prefix>snapshot:*` and deletes what
# it finds (RedisMetricsRepository::clear).
set -uo pipefail

WORK=${WORK:-$HOME/daravel-bench}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
REDIS_PORT=16391
PG_PORT=15442
LARAVEL_DASH=18181
DARAVEL_DASH=18182
JOBS=50
KEY="base64:$(head -c 32 /dev/urandom | base64)"
DB=(-e DB_CONNECTION=pgsql -e DB_HOST=127.0.0.1 -e DB_PORT=$PG_PORT
  -e DB_DATABASE=interop -e DB_USERNAME=interop -e DB_PASSWORD=secret)
SHARED=(-e REDIS_HOST=127.0.0.1 -e REDIS_PORT=$REDIS_PORT
  -e REDIS_PREFIX=shared-database- -e QUEUE_CONNECTION=redis
  -e APP_ENV=local -e APP_KEY="$KEY" "${DB[@]}")

docker run --rm -v "$WORK:/w" dart:stable rm -rf /w/src /w/horizon >/dev/null
mkdir -p "$WORK/src" "$WORK/pub-cache" "$WORK/horizon" || exit 1
tar -C "$REPO" --exclude=.git --exclude=.dart_tool --exclude=build \
  --exclude='docs/reviews' --exclude='docs/external-reviews' -cf - . |
  tar -C "$WORK/src" -xf - || exit 1

# The Laravel job: one row per run, with the worker that ran it.
cat >"$WORK/horizon/InteropJob.php" <<'PHP'
<?php

namespace App\Jobs;

use Illuminate\Contracts\Queue\ShouldQueue;
use Illuminate\Foundation\Queue\Queueable;
use Illuminate\Support\Facades\DB;

class InteropJob implements ShouldQueue
{
    use Queueable;

    public function __construct(public int $n) {}

    public function handle(): void
    {
        DB::table('interop_runs')->insert([
            'source' => 'laravel', 'job' => $this->n, 'worker' => 'laravel-'.getmypid(),
        ]);
    }
}
PHP

docker build --network=host -q -t daravel-bench-laravel "$REPO/bench/laravel" >/dev/null || exit 1
timeout 900 docker build --network=host -q -t daravel-interop-laravel-horizon - >/dev/null <<'DOCKER' || exit 1
FROM daravel-bench-laravel
RUN composer require laravel/horizon predis/predis --no-interaction -q
DOCKER
HORIZON_VERSION=$(docker run --rm --entrypoint sh daravel-interop-laravel-horizon -c \
  'cd /srv/app && composer show laravel/horizon | grep -m1 "^versions"' | sed 's/.*: \* //')
echo "laravel/horizon $HORIZON_VERSION"

# Daravel's side, compiled once (AOT: the workers are isolates of it).
timeout 900 docker run --rm --network host -v "$WORK/src:/src" \
  -v "$WORK/pub-cache:/root/.pub-cache" -w /src dart:stable sh -c \
  'dart pub get >/dev/null && cd bench && dart build cli -t bin/horizon_interop.dart -o build/horizon_interop >/dev/null' || {
  echo "Could not build bench/bin/horizon_interop.dart"
  exit 1
}

CONTAINERS=(horizon-redis horizon-pg laravel-horizon laravel-dash daravel-horizon daravel-dash)
cleanup() { docker rm -f "${CONTAINERS[@]}" >/dev/null 2>&1; }
trap cleanup EXIT

laravel() { # artisan args...
  docker run --rm --network host --entrypoint php "${SHARED[@]}" \
    -v "$WORK/horizon/InteropJob.php:/srv/app/app/Jobs/InteropJob.php:ro" \
    daravel-interop-laravel-horizon artisan "$@" 2>&1
}
laravel_detached() { # name artisan args...
  local name=$1
  shift
  docker run -d --name "$name" --network host --entrypoint php "${SHARED[@]}" \
    -v "$WORK/horizon/InteropJob.php:/srv/app/app/Jobs/InteropJob.php:ro" \
    daravel-interop-laravel-horizon artisan "$@" >/dev/null
}
daravel() { # args...
  docker run --rm --network host -v "$WORK/src:/src" -w /src/bench \
    "${SHARED[@]}" -e HORIZON_STORE=redis dart:stable build/horizon_interop/bundle/bin/horizon_interop "$@" 2>&1
}
daravel_detached() { # name [env...] -- args...
  local name=$1
  shift
  local env=()
  while [ "$1" != "--" ]; do env+=(-e "$1"); shift; done
  shift
  docker run -d --name "$name" --network host -v "$WORK/src:/src" -w /src/bench \
    "${SHARED[@]}" -e HORIZON_STORE=redis "${env[@]}" dart:stable \
    build/horizon_interop/bundle/bin/horizon_interop "$@" >/dev/null
}
redis() { docker exec horizon-redis redis-cli -p $REDIS_PORT "$@"; }
psql() { docker exec horizon-pg psql -p $PG_PORT -U interop -d interop -tAc "$1"; }

# Key names and types under a pattern, sorted: what is compared.
snapshot() { # pattern
  redis --scan --pattern "$1" | sort | while read -r key; do
    echo "$key $(redis type "$key")"
  done
}
# How many keys under a pattern expire within five minutes: heartbeats,
# master records and locks of a stopped side (Laravel Horizon's
# `monitor:time-to-clear` is a 60 s lock, Lock::get). Records kept for hours
# stay and are compared.
short_lived() { # pattern
  local count=0 ttl
  while read -r key; do
    [ -z "$key" ] && continue
    ttl=$(redis pttl "$key")
    [ "$ttl" -gt 0 ] && [ "$ttl" -lt 300000 ] && count=$((count + 1))
  done < <(redis --scan --pattern "$1")
  echo $count
}
# Waits until the keys under a pattern stop changing and none of them is
# short-lived any more, then prints them.
settled() { # pattern
  local before after
  before=$(snapshot "$1")
  for _ in $(seq 1 90); do
    sleep 5
    # Short-lived keys gone first, then the snapshot: one that expired
    # after it was listed would otherwise stay in it.
    [ "$(short_lived "$1")" = 0 ] || { before=$(snapshot "$1"); continue; }
    after=$(snapshot "$1")
    [ "$before" == "$after" ] && break
    before=$after
  done
  echo "$after"
}
wait_rows() { # source count
  for _ in $(seq 1 90); do
    [ "$(psql "select count(*) from interop_runs where source = '$1'")" -ge "$2" ] && return 0
    sleep 2
  done
  return 1
}

RESULTS=()
status=0
check() { # name ok-command-result(0/1) detail
  if [ "$2" -eq 0 ]; then
    RESULTS+=("PASS  $1")
  else
    RESULTS+=("FAIL  $1: $3")
    status=1
  fi
}

LARAVEL_KEYS='laravel_horizon:*'
# Daravel's keys: everything under the shared prefix but Laravel's queue.
daravel_keys() {
  snapshot 'shared-database-*' | grep -v '^shared-database-queues:default'
}
daravel_settled() {
  local before after
  before=$(daravel_keys)
  for _ in $(seq 1 90); do
    sleep 5
    [ "$(short_lived 'shared-database-*')" = 0 ] || { before=$(daravel_keys); continue; }
    after=$(daravel_keys)
    [ "$before" == "$after" ] && break
    before=$after
  done
  echo "$after"
}

start_services() {
  cleanup
  docker run -d --name horizon-redis --network host redis:7 --port $REDIS_PORT >/dev/null
  docker run -d --name horizon-pg --network host -e POSTGRES_USER=interop \
    -e POSTGRES_PASSWORD=secret -e POSTGRES_DB=interop postgres:17 \
    -c port=$PG_PORT >/dev/null
  for _ in $(seq 1 60); do
    docker exec horizon-pg pg_isready -U interop -p $PG_PORT >/dev/null 2>&1 && break
    sleep 1
  done
  sleep 2
  laravel migrate --force >/dev/null || { echo "Laravel could not migrate"; exit 1; }
  psql "create table interop_runs (id serial primary key, source text not null, job int not null, worker text not null)" >/dev/null
}

run_laravel() { # label: dispatch, work, dashboard, cleanup commands, stop
  local label=$1
  laravel tinker --execute="for (\$i = 0; \$i < $JOBS; \$i++) { App\\Jobs\\InteropJob::dispatch(\$i); }" >/dev/null
  laravel_detached laravel-horizon horizon
  wait_rows laravel $JOBS
  check "$label a: Laravel ran its $JOBS jobs" $? \
    "$(psql "select count(*) from interop_runs where source = 'laravel'") rows"
  laravel_detached laravel-dash serve --host=127.0.0.1 --port=$LARAVEL_DASH
  sleep 4
  local stats
  stats=$(curl -s "http://127.0.0.1:$LARAVEL_DASH/horizon/api/jobs/completed")
  [[ "$stats" == *'"name":"App\\Jobs\\InteropJob"'* ]]
  check "$label d: Laravel's dashboard lists its own jobs" $? "${stats:0:200}"
  [[ "$stats" != *'"queue":"daravel"'* ]]
  check "$label d: Laravel's dashboard lists no Daravel job" $? "${stats:0:200}"
  # e: Laravel's cleanup commands, run in the running Horizon's container so
  # horizon:terminate and horizon:purge reach its processes.
  for command in "horizon:snapshot" "horizon:clear --force" "horizon:purge" \
    "horizon:clear-metrics" "queue:clear redis --force" "horizon:terminate"; do
    # shellcheck disable=SC2086
    docker exec laravel-horizon php artisan $command >/dev/null 2>&1
  done
  docker stop -t 30 laravel-horizon laravel-dash >/dev/null 2>&1
  docker rm -f laravel-horizon laravel-dash >/dev/null 2>&1
}

run_daravel() { # label
  local label=$1
  daravel dispatch $JOBS >/dev/null
  daravel_detached daravel-horizon -- horizon
  wait_rows daravel $JOBS
  check "$label a: Daravel ran its $JOBS jobs" $? \
    "$(psql "select count(*) from interop_runs where source = 'daravel'") rows"
  daravel_detached daravel-dash APP_PORT=$DARAVEL_DASH -- serve
  sleep 4
  local recent
  recent=$(curl -s "http://127.0.0.1:$DARAVEL_DASH/horizon/api/jobs/completed")
  [[ "$recent" == *'"queue":"daravel"'* ]]
  check "$label d: Daravel's dashboard lists its own jobs" $? "${recent:0:200}"
  [[ "$recent" != *'"queue":"default"'* && "$recent" != *'App\\Jobs\\InteropJob'* ]]
  check "$label d: Daravel's dashboard lists no Laravel job" $? "${recent:0:200}"
  # c: every key of the store expires, but `monitored`.
  local missing=""
  while read -r key; do
    [ -z "$key" ] && continue
    [[ "$key" == *':monitored' ]] && continue
    [ "$(redis pttl "$key")" -gt 0 ] || missing="$missing $key"
  done < <(redis --scan --pattern 'shared-database-{daravel:horizon}:*')
  [ -z "$missing" ]
  check "$label c: every key of Daravel's store has a TTL" $? "$missing"
  # Daravel's own cleanup commands (f), while its Horizon runs.
  for command in "horizon:snapshot" "horizon:clear --queue=daravel --connection=redis --force" \
    "queue:clear redis --queue=daravel" "horizon:terminate"; do
    # shellcheck disable=SC2086
    docker exec daravel-horizon build/horizon_interop/bundle/bin/horizon_interop $command >/dev/null 2>&1
  done
  docker stop -t 30 daravel-horizon daravel-dash >/dev/null 2>&1
  docker rm -f daravel-horizon daravel-dash >/dev/null 2>&1
}

own_workers() { # label
  local label=$1
  local crossed
  crossed=$(psql "select count(*) from interop_runs where (source = 'laravel' and worker not like 'laravel-%') or (source = 'daravel' and worker not like 'daravel-%')")
  [ "$crossed" = 0 ]
  check "$label h: no job ran on the other side's workers" $? "$crossed rows"
  local laravel_n daravel_n
  laravel_n=$(psql "select count(*) from interop_runs where source = 'laravel'")
  daravel_n=$(psql "select count(*) from interop_runs where source = 'daravel'")
  [ "$laravel_n" = $JOBS ] && [ "$daravel_n" = $JOBS ]
  check "$label a: exactly $JOBS rows per side" $? "laravel=$laravel_n daravel=$daravel_n"
  local failed
  failed=$(psql "select count(*) from failed_jobs")
  [ "$failed" = 0 ]
  check "$label a: no failed_jobs" $? "$failed rows"
}

echo "== Order 1: Laravel Horizon first, then Daravel's"
start_services
[ -z "$(redis --scan --pattern '*')" ]
check "1: Redis starts empty" $? "$(redis --scan --pattern '*' | head -3)"
run_laravel 1
laravel_before=$(settled "$LARAVEL_KEYS")
[ -n "$laravel_before" ]
check "1: Laravel Horizon left keys to compare" $? "none"
run_daravel 1
laravel_after=$(settled "$LARAVEL_KEYS")
[ "$laravel_before" == "$laravel_after" ]
check "1 b/f: Laravel Horizon's keys as Laravel left them" $? \
  "$(diff <(echo "$laravel_before") <(echo "$laravel_after") | head -10 | tr '\n' ' ')"
own_workers 1

echo "== Order 2: Daravel's Horizon first, then Laravel Horizon"
start_services
run_daravel 2
daravel_before=$(daravel_settled)
[[ "$daravel_before" == *'{daravel:horizon}'* ]]
check "2: Daravel's Horizon left keys to compare" $? "none"
run_laravel 2
daravel_after=$(daravel_settled)
[ "$daravel_before" == "$daravel_after" ]
check "2 e: Daravel's keys as Daravel left them" $? \
  "$(diff <(echo "$daravel_before") <(echo "$daravel_after") | head -10 | tr '\n' ' ')"
own_workers 2

echo "== g: FLUSHDB / FLUSHALL"
laravel_flush=$(docker run --rm --entrypoint sh daravel-interop-laravel-horizon -c \
  'grep -rniE "flushdb|flushall" /srv/app/vendor/laravel/horizon/src' | wc -l)
[ "$laravel_flush" = 0 ]
check "g: laravel/horizon $HORIZON_VERSION sends no FLUSHDB/FLUSHALL" $? "$laravel_flush lines"
# Daravel: the only mention in the Redis client is its list of commands
# without a key (cluster routing); nothing sends it.
daravel_flush=$(grep -rnE "'FLUSHDB'|'FLUSHALL'" "$REPO/packages/daravel_redis/lib" \
  "$REPO/packages/daravel_horizon/lib" | grep -v "client.dart" | wc -l)
[ "$daravel_flush" = 0 ]
check "g: daravel_redis and daravel_horizon send no FLUSHDB/FLUSHALL" $? "$daravel_flush lines"

echo
printf '%s\n' "${RESULTS[@]}"
[ $status -eq 0 ] && echo "All Horizon coexistence checks passed." || echo "Some Horizon coexistence checks failed."
exit $status
