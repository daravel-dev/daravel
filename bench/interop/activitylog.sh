#!/usr/bin/env bash
# Laravel 12 with spatie/laravel-activitylog 4.10
# and Daravel with daravel_activitylog on one SQLite database (Linux and
# Docker): Spatie's migrations create the table; activities written by
# either are read by the other, model changes are stored alike.
#
#   bash bench/interop/activitylog.sh
set -uo pipefail

WORK=${WORK:-$HOME/daravel-bench}
REPO=$(cd "$(dirname "$0")/../.." && pwd)

docker run --rm -v "$WORK:/w" dart:stable rm -rf /w/src /w/activitylog >/dev/null
mkdir -p "$WORK/src" "$WORK/pub-cache" "$WORK/activitylog"
tar -C "$REPO" --exclude=.git --exclude=.dart_tool --exclude=build \
  --exclude='docs/reviews' --exclude='docs/external-reviews' -cf - . |
  tar -C "$WORK/src" -xf -

docker build --network=host -q -t daravel-bench-laravel "$REPO/bench/laravel" >/dev/null
docker build --network=host -q -t daravel-interop-laravel-activitylog - >/dev/null <<'DOCKER'
FROM daravel-bench-laravel
RUN composer require spatie/laravel-activitylog:4.10.2 --no-interaction -q \
 && php artisan vendor:publish --provider="Spatie\Activitylog\ActivitylogServiceProvider" --tag=activitylog-migrations -q \
 && php -r '$f = "app/Models/User.php"; file_put_contents($f, str_replace("class User extends Authenticatable\n{", "class User extends Authenticatable\n{\n    use \Spatie\Activitylog\Traits\LogsActivity;\n    use \Spatie\Activitylog\Traits\CausesActivity;\n    public function getActivitylogOptions(): \Spatie\Activitylog\LogOptions { return \Spatie\Activitylog\LogOptions::defaults()->logOnly([\"name\", \"email\", \"created_at\"])->logOnlyDirty(); }\n", file_get_contents($f)));'
DOCKER

DB=(-e DB_CONNECTION=sqlite -e DB_DATABASE=/shared/app.sqlite)
laravel() { # php code
  docker run --rm -v "$WORK/activitylog:/shared" --entrypoint php "${DB[@]}" \
    daravel-interop-laravel-activitylog artisan tinker --execute="$1" 2>&1 | grep -v '^$' | tail -1
}
daravel() { # step [args]
  docker run --rm -v "$WORK/activitylog:/shared" -v "$WORK/src:/src" \
    -v "$WORK/pub-cache:/root/.pub-cache" -w /src/bench "${DB[@]}" dart:stable \
    sh -c "dart pub get >/dev/null 2>&1; dart run bin/activitylog_interop.dart $*" 2>&1 | tail -1
}

status=0
check() { # name expected actual
  if [[ "$3" == *"$2"* ]]; then echo "PASS $1"; else echo "FAIL $1: expected [$2] in [$3]"; status=1; fi
}

echo "== Laravel migrates (Spatie's own migrations) and logs"
docker run --rm -v "$WORK/activitylog:/shared" --entrypoint sh "${DB[@]}" \
  daravel-interop-laravel-activitylog -c 'touch /shared/app.sqlite && php artisan migrate --force -q' >/dev/null
id=$(laravel '$u = App\Models\User::create(["name" => "Ana", "email" => "ana@example.com", "password" => "x"]);
  $u->update(["name" => "Ana B"]);
  Spatie\Activitylog\Facades\LogBatch::withinBatch(fn () => activity("security")->performedOn($u)->causedBy($u)->withProperties(["ip" => "10.0.0.7"])->log("Laravel :causer.name from :properties.ip"));
  echo $u->id;')

echo "== Daravel reads Laravel's activities"
read=$(daravel read "$id")
check "created, as Laravel logged it" '"created",{"attributes":{"name":"Ana","email":"ana@example.com","created_at":"' "$read"
check "updated with old values" '"updated",{"attributes":{"name":"Ana B"},"old":{"name":"Ana"}}' "$read"
check "manual activity, subject, causer, batch" '"Laravel Ana B from 10.0.0.7","security",{"ip":"10.0.0.7"},"Ana B","Ana B",true' "$read"

echo "== Daravel logs; Laravel reads"
check "Daravel logged" "logged" "$(daravel write "$id")"
check "Laravel reads Daravel's model change" '{"attributes":{"name":"Ana C"},"old":{"name":"Ana B"}}' \
  "$(laravel 'echo json_encode(Spatie\Activitylog\Models\Activity::forSubject(App\Models\User::find('"$id"'))->where("event", "updated")->latest("id")->first()->changes());')"
check "Laravel reads Daravel's manual activity" '["Daravel Ana C","daravel","Ana C","Ana C",{"ip":"10.0.0.8"},2]' \
  "$(laravel '$a = Spatie\Activitylog\Models\Activity::inLog("daravel")->first(); echo json_encode([$a->description, $a->log_name, $a->subject->name, $a->causer->name, $a->properties, Spatie\Activitylog\Models\Activity::forBatch($a->batch_uuid)->count()]);')"
check "a user Daravel created logs as Laravel logs one" "same" \
  "$(laravel '$d = Spatie\Activitylog\Models\Activity::where("description", "created")->where("subject_id", "!=", '"$id"')->first(); $l = Spatie\Activitylog\Models\Activity::where("description", "created")->where("subject_id", '"$id"')->first();
    echo array_keys($d->changes()["attributes"]) === array_keys($l->changes()["attributes"]) && preg_match("/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{6}Z$/", $d->changes()["attributes"]["created_at"]) ? "same" : json_encode([$d->changes(), $l->changes()]);')"

[ $status -eq 0 ] && echo "All activitylog interop checks passed." || echo "Some activitylog interop checks failed."
exit $status
