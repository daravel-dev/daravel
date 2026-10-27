#!/usr/bin/env bash
# LiveKit's PHP server SDK (agence104/livekit-server-sdk, as Laravel apps
# use it) and daravel_livekit (Linux and Docker): each verifies the other's
# access tokens, and each accepts the other's signed webhooks.
#
#   bash bench/interop/livekit.sh
set -uo pipefail

WORK=${WORK:-$HOME/daravel-bench}
REPO=$(cd "$(dirname "$0")/../.." && pwd)
KEY=interop-key
SECRET=interop-secret-that-is-long-enough

docker run --rm -v "$WORK:/w" dart:stable rm -rf /w/src /w/livekit-php >/dev/null
mkdir -p "$WORK/src" "$WORK/pub-cache" "$WORK/livekit-php"
tar -C "$REPO" --exclude=.git --exclude=.dart_tool --exclude=build \
  --exclude='docs/reviews' --exclude='docs/external-reviews' -cf - . |
  tar -C "$WORK/src" -xf -

# The SDK from Packagist, as a Laravel app installs it.
docker run --rm -v "$WORK/livekit-php:/app" -w /app composer:2 \
  composer require agence104/livekit-server-sdk:^1.3 --no-interaction -q --ignore-platform-reqs

php() { # code
  docker run --rm -v "$WORK/livekit-php:/app" -v "$WORK/src/bench/interop:/data" -w /app php:8.3-cli \
    php -r "require 'vendor/autoload.php'; use Agence104\\LiveKit\\{AccessToken, AccessTokenOptions, VideoGrant, WebhookReceiver}; $1" 2>&1
}
daravel() { # step args...
  docker run --rm -v "$WORK/src:/src" -v "$WORK/pub-cache:/root/.pub-cache" -w /src/bench dart:stable \
    sh -c "dart pub get >/dev/null 2>&1; dart run bin/livekit_interop.dart $*" 2>&1 | tail -1 |
    sed -E 's/^(Running build hooks\.\.\.)*//' # printed without a newline
}

status=0
check() { # name expected actual
  if [[ "$3" == *"$2"* ]]; then echo "PASS $1"; else echo "FAIL $1: expected [$2] in [$3]"; status=1; fi
}

# The first Daravel run compiles.
daravel token >/dev/null

echo "== PHP signs a join token, Daravel verifies it"
token=$(php "echo (new AccessToken('$KEY', '$SECRET'))->init((new AccessTokenOptions())->setIdentity('student-9')->setName('Siswa')->setTtl(600))->setGrant((new VideoGrant())->setRoomJoin()->setRoomName('class-7a'))->toJwt();" | tail -1)
check "Daravel reads PHP's token" "identity=student-9 name=Siswa room=class-7a admin=null" "$(daravel verify "$token")"

echo "== Daravel signs a join token, PHP reads it"
token=$(daravel token)
# fromJwt checks the signature and the issuer; the identity is the `sub`.
check "PHP reads Daravel's token" "teacher-1|Guru|class-7a|1" "$(php "\$g = (new AccessToken('$KEY', '$SECRET'))->fromJwt('$token'); \$sub = \Firebase\JWT\JWT::decode('$token', new \Firebase\JWT\Key('$SECRET', 'HS256'))->sub; echo \$sub, '|', \$g->getName(), '|', \$g->getVideoGrant()->getRoom(), '|', (int) \$g->getVideoGrant()->isRoomAdmin();" | tail -1)"

echo "== Webhooks, both ways"
cat > "$WORK/src/bench/interop/webhook.json" <<'JSON'
{"event":"room_finished","id":"EV_interop","room":{"sid":"RM_x","name":"class-7a"}}
JSON
header=$(php "\$body = file_get_contents('/data/webhook.json'); echo (new AccessToken('$KEY', '$SECRET'))->init((new AccessTokenOptions())->setTtl(300))->setGrant(new VideoGrant())->setSha256(base64_encode(hash('sha256', \$body, true)))->toJwt();" | tail -1)
check "Daravel accepts PHP's webhook" "event=room_finished room=class-7a" "$(daravel receive /src/bench/interop/webhook.json "$header")"
header=$(daravel sign /src/bench/interop/webhook.json)
check "PHP accepts Daravel's webhook (verified)" "room_finished" "$(php "echo (new WebhookReceiver('$KEY', '$SECRET'))->receive(file_get_contents('/data/webhook.json'), '$header')->getEvent();" | tail -1)"
check "PHP refuses a tampered body" "does not match" "$(php "try { (new WebhookReceiver('$KEY', '$SECRET'))->receive(str_replace('7a', '7b', file_get_contents('/data/webhook.json')), '$header'); echo 'accepted'; } catch (\\Exception \$e) { echo \$e->getMessage(); }" | tail -1)"

[ $status -eq 0 ] && echo "All LiveKit interop checks passed." || echo "Some LiveKit interop checks failed."
exit $status
