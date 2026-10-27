# Laravel 12 + Octane (FrankenPHP) with the benchmark endpoints of
# bench/lib/bench_app.dart. Built and run by bench/laravel/compare.sh.
FROM dunglas/frankenphp:1-php8.4

RUN install-php-extensions pcntl pdo_sqlite pdo_pgsql zip opcache @composer

# --no-scripts: the skeleton's post-create scripts wait for input; the overlay
# provides .env and the key.
RUN composer create-project laravel/laravel:^12.0 /srv/app --no-interaction --prefer-dist --no-scripts
WORKDIR /srv/app
RUN composer require laravel/octane:^2.0 --no-interaction \
 && composer install --no-dev --optimize-autoloader --no-interaction

# Production PHP settings, with OPcache not checking file timestamps.
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini" \
 && printf 'opcache.enable=1\nopcache.validate_timestamps=0\nopcache.memory_consumption=256\nopcache.max_accelerated_files=20000\n' \
    > "$PHP_INI_DIR/conf.d/zz-bench.ini"

COPY overlay/ /srv/app/
# The SQLite settings Daravel's driver uses: wait for locks, WAL, NORMAL sync.
RUN sed -i "s/'busy_timeout' => null/'busy_timeout' => 5000/; s/'journal_mode' => null/'journal_mode' => 'wal'/; s/'synchronous' => null/'synchronous' => 'normal'/" config/database.php
COPY entrypoint.sh /usr/local/bin/bench-entrypoint
RUN chmod +x /usr/local/bin/bench-entrypoint \
 && php artisan octane:install --server=frankenphp --no-interaction

ENTRYPOINT ["bench-entrypoint"]
