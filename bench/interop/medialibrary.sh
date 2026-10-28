#!/usr/bin/env bash
# Laravel 12 with spatie/laravel-medialibrary 11.23 and Daravel with
# daravel_medialibrary on one SQLite database and one public disk (Linux and
# Docker): Spatie's migration creates the table; each reads, serves and
# deletes the media the other added, conversions included.
#
#   bash bench/interop/medialibrary.sh
set -uo pipefail

WORK=${WORK:-$HOME/daravel-bench}
REPO=$(cd "$(dirname "$0")/../.." && pwd)

docker run --rm -v "$WORK:/w" dart:stable rm -rf /w/src /w/medialibrary >/dev/null
mkdir -p "$WORK/src" "$WORK/pub-cache" "$WORK/medialibrary/public"
tar -C "$REPO" --exclude=.git --exclude=.dart_tool --exclude=build \
  --exclude='docs/reviews' --exclude='docs/external-reviews' -cf - . |
  tar -C "$WORK/src" -xf -

docker build --network=host -q -t daravel-bench-laravel "$REPO/bench/laravel" >/dev/null
docker build --network=host -q -t daravel-interop-laravel-medialibrary - >/dev/null <<'DOCKER'
FROM daravel-bench-laravel
RUN install-php-extensions gd exif \
 && composer require spatie/laravel-medialibrary:11.23.11 --no-interaction -q \
 && php artisan vendor:publish --provider="Spatie\MediaLibrary\MediaLibraryServiceProvider" --tag=medialibrary-migrations -q \
 && php -r '$f = "app/Models/User.php"; file_put_contents($f, str_replace("class User extends Authenticatable\n{", "class User extends Authenticatable implements \Spatie\MediaLibrary\HasMedia\n{\n    use \Spatie\MediaLibrary\InteractsWithMedia;\n    public function registerMediaConversions(?\Spatie\MediaLibrary\MediaCollections\Models\Media \$media = null): void { \$this->addMediaConversion(\"thumb\")->fit(\Spatie\Image\Enums\Fit::Crop, 100, 100)->nonQueued(); \$this->addMediaConversion(\"preview\")->width(300)->nonQueued(); }\n", file_get_contents($f)));'
DOCKER

DB=(-e DB_CONNECTION=sqlite -e DB_DATABASE=/shared/app.sqlite -e APP_URL=http://localhost -e QUEUE_CONNECTION=sync)
DISK=(-v "$WORK/medialibrary:/shared" -v "$WORK/medialibrary/public:/srv/app/storage/app/public")
laravel() { # php code
  docker run --rm "${DISK[@]}" --entrypoint php "${DB[@]}" \
    daravel-interop-laravel-medialibrary artisan tinker --execute="$1" 2>&1 | grep -v '^$' | tail -1
}
daravel() { # step [args]
  docker run --rm -v "$WORK/medialibrary:/shared" -v "$WORK/src:/src" \
    -v "$WORK/pub-cache:/root/.pub-cache" -w /src/bench "${DB[@]}" dart:stable \
    sh -c "dart pub get >/dev/null 2>&1; dart run bin/medialibrary_interop.dart $*" 2>&1 | tail -1
}

status=0
check() { # name expected actual
  if [[ "$3" == *"$2"* ]]; then echo "PASS $1"; else echo "FAIL $1: expected [$2] in [$3]"; status=1; fi
}

echo "== Laravel migrates (Spatie's own migration) and adds an avatar"
docker run --rm "${DISK[@]}" --entrypoint sh "${DB[@]}" \
  daravel-interop-laravel-medialibrary -c 'touch /shared/app.sqlite && php artisan migrate --force -q' >/dev/null
added=$(laravel '$u = App\Models\User::create(["name" => "Ana", "email" => "ana@example.com", "password" => "x"]);
  $i = imagecreatetruecolor(600, 400); imagefill($i, 0, 0, imagecolorallocate($i, 200, 30, 30)); imagejpeg($i, "/tmp/Laravel photo.jpg");
  $m = $u->addMedia("/tmp/Laravel photo.jpg")->withCustomProperties(["alt" => "from laravel"])->toMediaCollection("avatars");
  echo $u->id . " " . $m->id;')
read -r user laravel_media <<<"$added"
check "Laravel added an avatar" "1 1" "$added"

echo "== Daravel reads Laravel's media"
read=$(daravel read "$user")
check "the row: file name, mime, custom property" '"file":"Laravel-photo.jpg","mime":"image/jpeg","alt":"from laravel"' "$read"
check "Spatie's generated_conversions" '"generated":{"thumb":true,"preview":true}' "$read"
check "Laravel's conversions, where Spatie puts them" '"thumb":[100,100],"preview":[300,200]' "$read"
check "the same URL Laravel serves" '"url":"http://localhost/storage/1/conversions/Laravel-photo-thumb.jpg","size":true' "$read"

echo "== Daravel adds a photo; Laravel reads it"
written=$(daravel write "$user")
check "Daravel added a photo" "written" "$written"
daravel_media=${written##* }
check "Laravel reads the row, its order and its conversions" '["Daravel-photo.jpg","photos","from daravel",2,true,true,[100,100],[300,200]]' \
  "$(laravel '$m = Spatie\MediaLibrary\MediaCollections\Models\Media::find('"$daravel_media"');
    echo json_encode([$m->file_name, $m->collection_name, $m->getCustomProperty("alt"), $m->order_column, $m->hasGeneratedConversion("thumb"), file_exists($m->getPath()), array_slice(getimagesize($m->getPath("thumb")), 0, 2), array_slice(getimagesize($m->getPath("preview")), 0, 2)]);')"
check "Laravel serves it at Daravel's URL" "http://localhost/storage/$daravel_media/conversions/Daravel-photo-thumb.jpg" \
  "$(laravel 'echo App\Models\User::find('"$user"')->getFirstMediaUrl("photos", "thumb");')"

echo "== Each deletes the other's media"
check "Laravel deletes Daravel's photo and its files" '[0,false]' \
  "$(laravel 'Spatie\MediaLibrary\MediaCollections\Models\Media::find('"$daravel_media"')->delete(); echo json_encode([App\Models\User::find('"$user"')->getMedia("photos")->count(), is_dir(storage_path("app/public/'"$daravel_media"'"))]);')"
check "Daravel deletes Laravel's avatar and its files" "deleted" "$(daravel delete "$laravel_media")"
check "Laravel sees no media left" "0" "$(laravel 'echo Spatie\MediaLibrary\MediaCollections\Models\Media::count();')"

[ $status -eq 0 ] && echo "All medialibrary interop checks passed." || echo "Some medialibrary interop checks failed."
exit $status
