#!/usr/bin/env bash
# Laravel 12 with spatie/laravel-permission and Daravel with
# daravel_permission on one SQLite database (Linux and Docker): Spatie's
# migration creates the tables, roles given by either are seen by the other.
#
#   bash bench/interop/permission.sh
set -uo pipefail

WORK=${WORK:-$HOME/daravel-bench}
REPO=$(cd "$(dirname "$0")/../.." && pwd)

docker run --rm -v "$WORK:/w" dart:stable rm -rf /w/src /w/permission >/dev/null
mkdir -p "$WORK/src" "$WORK/pub-cache" "$WORK/permission"
tar -C "$REPO" --exclude=.git --exclude=.dart_tool --exclude=build \
  --exclude='docs/reviews' --exclude='docs/external-reviews' -cf - . |
  tar -C "$WORK/src" -xf -

docker build --network=host -q -t daravel-bench-laravel "$REPO/bench/laravel" >/dev/null
docker build --network=host -q -t daravel-interop-laravel-permission - >/dev/null <<'DOCKER'
FROM daravel-bench-laravel
RUN composer require spatie/laravel-permission:^6.0 --no-interaction -q \
 && php artisan vendor:publish --provider="Spatie\Permission\PermissionServiceProvider" -q \
 && php -r '$f = "app/Models/User.php"; file_put_contents($f, str_replace("class User extends Authenticatable\n{", "class User extends Authenticatable\n{\n    use \Spatie\Permission\Traits\HasRoles;\n", file_get_contents($f)));'
DOCKER

DB=(-e DB_CONNECTION=sqlite -e DB_DATABASE=/shared/app.sqlite)
laravel() { # php code
  docker run --rm -v "$WORK/permission:/shared" --entrypoint php "${DB[@]}" \
    daravel-interop-laravel-permission artisan tinker --execute="$1" 2>&1 | grep -v '^$' | tail -1
}
daravel() { # step user-id
  docker run --rm -v "$WORK/permission:/shared" -v "$WORK/src:/src" \
    -v "$WORK/pub-cache:/root/.pub-cache" -w /src/bench "${DB[@]}" dart:stable \
    sh -c "dart pub get >/dev/null 2>&1; dart run bin/permission_interop.dart $1 $2" 2>&1 | tail -1
}

status=0
check() { # name expected actual
  if [[ "$3" == *"$2"* ]]; then echo "PASS $1"; else echo "FAIL $1: expected [$2] in [$3]"; status=1; fi
}

echo "== Laravel migrates (Spatie's own migration) and assigns a role"
docker run --rm -v "$WORK/permission:/shared" --entrypoint sh "${DB[@]}" \
  daravel-interop-laravel-permission -c 'touch /shared/app.sqlite && php artisan migrate --force -q' >/dev/null
id=$(laravel '$u = App\Models\User::create(["name" => "Ana", "email" => "ana@example.com", "password" => "x"]);
  $r = Spatie\Permission\Models\Role::create(["name" => "writer"]);
  Spatie\Permission\Models\Permission::create(["name" => "posts.edit"]);
  $r->givePermissionTo("posts.edit"); $u->assignRole("writer"); echo $u->id;')

echo "== Daravel reads Laravel's roles and permissions"
check "role and permission via role" "writer=true edit=true publish=false" "$(daravel check "$id")"

echo "== Daravel grants; Laravel sees it"
check "Daravel granted" "granted" "$(daravel grant "$id")"
check "Laravel reads Daravel's role and permission" '[true,true,["editor","writer"]]' \
  "$(laravel '$u = App\Models\User::find('"$id"'); echo json_encode([$u->hasRole("editor"), $u->can("posts.publish"), $u->getRoleNames()->sort()->values()]);')"
check "Daravel reads it back" "writer=true edit=true publish=true" "$(daravel check "$id")"

[ $status -eq 0 ] && echo "All permission interop checks passed." || echo "Some permission interop checks failed."
exit $status
