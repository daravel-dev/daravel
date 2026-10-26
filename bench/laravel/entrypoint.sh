#!/bin/sh
# MODE=octane: Laravel Octane on FrankenPHP worker mode, WORKERS workers.
# MODE=classic: FrankenPHP without worker mode, one bootstrap per request
#               (what php-fpm does).
set -e
cd /srv/app
php artisan config:cache >/dev/null
php artisan route:cache >/dev/null
php artisan event:cache >/dev/null
case "${MODE:-octane}" in
  octane)
    exec php artisan octane:frankenphp --host=127.0.0.1 --port="${PORT:-8000}" \
      --workers="${WORKERS:-1}" --max-requests=1000000 --log-level=error ;;
  classic)
    exec frankenphp php-server --root public --listen "127.0.0.1:${PORT:-8000}" ;;
esac
