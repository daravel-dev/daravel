#!/usr/bin/env bash
# Daravel beside a real Laravel 8, 9, 10, 11, 12 and 13 on one SQLite
# database (Linux and Docker; network access for Composer):
#
#   bash bench/interop/laravel_matrix.sh
#   VERSIONS="8 13" bash bench/interop/laravel_matrix.sh
#
# Each laravel/laravel skeleton comes from Composer, on a PHP it supports.
# audit.block-insecure is off because Composer refuses every release of the
# end-of-life versions; these images only run this test.
#
# A. Sessions, in php and json (Laravel 9 added json) and with and without
#    SESSION_ENCRYPT: Laravel's Store writes one, Daravel reads and updates
#    it, Laravel reads it back with the user still logged in; and the other
#    way round for a session Daravel creates.
# B. Crypt and bcrypt, both ways.
#    The `web` guard both ways: logged in on one side, logged in on the other.
# C. Byte for byte, with COMPAT_LARAVEL_VERSION: the 422, 404 and 405 bodies,
#    accepted and declined messages, model JSON (snake_case relations,
#    decimal:N), paginator JSON and the 401 a guest gets before bindings run.
# D. dartisan adopt on the real project.
set -uo pipefail

WORK=${WORK:-$HOME/daravel-bench}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
VERSIONS=${VERSIONS:-8 9 10 11 12 13}
KEY="base64:$(head -c 32 /dev/urandom | base64)"

# Created here first: a directory Docker creates for a mount is root's.
mkdir -p "$WORK" || exit 1
docker run --rm -v "$WORK:/w" dart:stable rm -rf /w/src /w/matrix >/dev/null
mkdir -p "$WORK/src" "$WORK/pub-cache" "$WORK/matrix" || exit 1
tar -C "$REPO" --exclude=.git --exclude=.dart_tool --exclude=build \
  --exclude=node_modules --exclude='docs/reviews' --exclude='docs/external-reviews' -cf - . |
  tar -C "$WORK/src" -xf - || exit 1
# Host network: from the bridge pub.dev resolves to IPv6 only and hangs.
timeout 600 docker run --rm --network host -v "$WORK/src:/src" \
  -v "$WORK/pub-cache:/root/.pub-cache" -w /src dart:stable sh -c \
  'dart pub get && cd bench && dart build cli -t bin/laravel_matrix.dart -o build/matrix' >/dev/null 2>&1 || {
  echo "Could not build bench/bin/laravel_matrix.dart"
  exit 1
}

php_for() { case $1 in 8 | 9 | 10) echo 8.1 ;; 11 | 12) echo 8.2 ;; *) echo 8.3 ;; esac; }

image_for() { # major
  local image="daravel-interop-laravel-$1"
  timeout 900 docker build --network=host -q -t "$image" - >/dev/null <<DOCKER
FROM php:$(php_for "$1")-cli
RUN apt-get update -qq && apt-get install -qq -y git unzip >/dev/null
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
RUN composer config --global audit.block-insecure false \
 && composer create-project laravel/laravel:^$1.0 /app --no-interaction --prefer-dist --no-scripts -q \
 && cp /app/.env.example /app/.env
DOCKER
}

status=0
check() { # name expected actual
  if [[ "$3" == *"$2"* ]]; then
    echo "  PASS $1"
  else
    echo "  FAIL $1: expected [$2] in [$3]"
    status=1
  fi
}
field() { sed -E "s/.*\"$1\":\"?([^\",}]*)\"?.*/\1/"; }

for major in $VERSIONS; do
  image="daravel-interop-laravel-$major"
  image_for "$major" || {
    echo "FAIL Laravel $major: the image did not build"
    status=1
    continue
  }
  shared="$WORK/matrix/$major"
  mkdir -p "$shared"
  env_for=(-e APP_ENV=production -e APP_DEBUG=false -e "APP_KEY=$KEY" -e APP_CIPHER=AES-256-CBC
    -e DB_CONNECTION=sqlite -e DB_DATABASE=/shared/app.sqlite -e SESSION_DRIVER=database
    -e BCRYPT_ROUNDS=10 -e HASH_DRIVER=bcrypt -e "COMPAT_LARAVEL_VERSION=$major")
  laravel() { # env... -- step args
    local extra=()
    while [[ $1 != -- ]]; do extra+=("$1"); shift; done
    shift
    docker run --rm -v "$shared:/shared" -v "$REPO/bench/interop:/harness:ro" -w /app \
      "${env_for[@]}" "${extra[@]}" "$image" php /harness/laravel_matrix.php "$@" 2>&1 | tail -1
  }
  daravel() { # env... -- step args
    local extra=()
    while [[ $1 != -- ]]; do extra+=("$1"); shift; done
    shift
    timeout 300 docker run --rm --network host -v "$shared:/shared" -v "$WORK/src:/src" \
      -v "$WORK/pub-cache:/root/.pub-cache" -w /src/bench "${env_for[@]}" "${extra[@]}" dart:stable \
      build/matrix/bundle/bin/laravel_matrix "$@" 2>&1 | tail -1
  }

  docker run --rm -v "$WORK:/w" dart:stable rm -rf "/w/matrix/$major/app.sqlite" >/dev/null
  docker run --rm -v "$shared:/shared" "$image" sh -c 'touch /shared/app.sqlite; chmod -R a+rwX /shared'
  echo "== Laravel $(laravel -- migrate)"

  formats="php json"
  [ "$major" = 8 ] && formats=php
  for format in $formats; do
    for encrypt in false true; do
      opts=(-e "SESSION_SERIALIZATION=$format" -e "SESSION_ENCRYPT=$encrypt")
      echo " sessions: $format, encrypt=$encrypt"
      written=$(laravel "${opts[@]}" -- write)
      id=$(field id <<<"$written")
      cookie=$(sed -E 's/.*"cookie":"([^"]*)".*/\1/; s/\\\//\//g' <<<"$written")
      # A configured format that differs: the row must keep its own.
      other=php; [ "$format" = php ] && [ "$major" != 8 ] && other=json
      touched=$(daravel "${opts[@]}" -e "SESSION_SERIALIZATION=$other" -- touch "$cookie")
      check "Daravel reads Laravel's session" '"name":"Ana é"' "$touched"
      check "the same id, not a new session" "\"id\":\"$id\"" "$touched"
      read=$(laravel "${opts[@]}" -- read "$id")
      check "Laravel: still logged in" '"login":7' "$read"
      check "Laravel: its data and Daravel's" '"name":"Ana é","login":7,"daravel":"héllo"' "$read"
      check "Daravel sees Laravel's flash data" '"status":"saved"' "$touched"
      check "Laravel: the flash data lasted that one request" '"status":null' "$read"
      check "Laravel: CSRF token kept" '"token":40' "$read"
      if [ "$encrypt" = false ]; then
        check "the row is still $format" "$format" "$(laravel "${opts[@]}" -- format "$id")"
      fi

      check "Daravel's web guard: logged in on Laravel, logged in here" '"user":7' \
        "$(daravel "${opts[@]}" -e "SESSION_SERIALIZATION=$other" -- whoami "$cookie")"
      signed=$(daravel "${opts[@]}" -- signin)
      check "Daravel's guard logs in with Laravel's bcrypt password" '"ok":true' "$signed"
      read=$(laravel "${opts[@]}" -- read "$(field id <<<"$signed")")
      check "Laravel's guard: logged in on Daravel, logged in here" '"user":7' "$read"
      case $major in
      12 | 13) hash=true ;;
      *) hash=null ;;
      esac
      check "AuthenticateSession accepts the session" "\"password_hash\":$hash" "$read"

      created=$(daravel "${opts[@]}" -- touch)
      new=$(field id <<<"$created")
      read=$(laravel "${opts[@]}" -- read "$new")
      check "Laravel reads a session Daravel created" '"daravel":"héllo"' "$read"
      check "with its CSRF token" '"token":40' "$read"
    done
  done

  echo " Crypt and bcrypt"
  from=$(laravel -- crypt)
  a=$(sed -E 's/.*"encrypt":"([^"]*)".*/\1/' <<<"$from")
  b=$(sed -E 's/.*"string":"([^"]*)".*/\1/' <<<"$from")
  c=$(sed -E 's/.*"hash":"([^"]*)".*/\1/; s/\\\//\//g' <<<"$from")
  check "Daravel reads Laravel's" '"encrypt":"fröm laravel","string":"fröm laravel","hash":true' \
    "$(daravel -- decrypt "$a" "$b" "$c")"
  from=$(daravel -- crypt)
  a=$(sed -E 's/.*"encrypt":"([^"]*)".*/\1/' <<<"$from")
  b=$(sed -E 's/.*"string":"([^"]*)".*/\1/' <<<"$from")
  c=$(sed -E 's/.*"hash":"([^"]*)".*/\1/' <<<"$from")
  check "Laravel reads Daravel's" '"encrypt":"fröm daravel","string":"fröm daravel","hash":true' \
    "$(laravel -- decrypt "$a" "$b" "$c")"

  echo " 422, 404 and 405 bodies"
  expected=$(laravel -- wire)
  actual=$(daravel -- wire)
  if [ "$expected" = "$actual" ]; then
    echo "  PASS identical"
  else
    echo "  FAIL bodies differ"
    echo "   Laravel: $expected"
    echo "   Daravel: $actual"
    status=1
  fi

  echo " dartisan adopt"
  project="$shared/laravel"
  mkdir -p "$project"
  docker run --rm "$image" tar -C /app -cf - artisan composer.lock config/session.php |
    tar -C "$project" -xf -
  printf 'APP_KEY=%s\nDB_CONNECTION=sqlite\nDB_DATABASE=/shared/app.sqlite\n' "$KEY" >"$project/.env"
  adopted=$(timeout 300 docker run --rm --network host -v "$shared:/shared" -v "$WORK/src:/src" \
    -v "$WORK/pub-cache:/root/.pub-cache" -w /src/apps/daravel_starter dart:stable sh -c \
    'rm -f .env .env.before-adopt; dart run bin/dartisan.dart adopt /shared/laravel --skip-database >/dev/null 2>&1; echo "exit=$?"; cat .env; rm -f .env .env.before-adopt' 2>&1)
  check "adopt succeeded" "exit=0" "$adopted"
  check "COMPAT_LARAVEL_VERSION=$major" "COMPAT_LARAVEL_VERSION=$major" "$adopted"
  session=php
  [ "$major" = 13 ] && session=json
  check "SESSION_SERIALIZATION=$session" "SESSION_SERIALIZATION=$session" "$adopted"
done

[ $status -eq 0 ] && echo "All Laravel matrix checks passed." || echo "Some Laravel matrix checks failed."
exit $status
