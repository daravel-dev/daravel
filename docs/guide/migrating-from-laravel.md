# Migrating from Laravel, route by route

You do not have to rewrite a Laravel application in one go. Because Daravel
reads and writes Laravel's formats (see [Laravel coexistence](laravel-coexistence.md)),
both applications can serve one API from one database while endpoints move
across one at a time. This is the *Strangler Fig* pattern: a reverse proxy
sends the endpoints that have been ported to Daravel and everything else to
Laravel, and the Daravel part grows until Laravel can be switched off. It
also works in the other direction.

```
                 ┌──────────────── reverse proxy (Caddy / nginx) ───────────────┐
 clients ──TLS──▶│  /api/orders*, /api/reports*  ──▶ Daravel  (127.0.0.1:8000)  │
                 │  everything else              ──▶ Laravel  (php-fpm)         │
                 └──────────────────────────────────────────────────────────────┘
                                 both ──▶ one PostgreSQL database
```

## Before you start

- **PostgreSQL.** Daravel's runtime drivers are SQLite and PostgreSQL; the
  MySQL driver is not available yet. A Laravel application on MySQL has to
  move to PostgreSQL first (or wait for the MySQL driver).
- **API with bearer tokens.** Sanctum personal access tokens work on both
  sides. Session cookies, CSRF and Sanctum's stateful SPA mode are not
  shared yet, so routes that depend on a Laravel session stay in Laravel.
- **Laravel 11 or 12** formats. The [conformance suite](laravel-coexistence.md)
  pins Laravel 12 and Sanctum 4.

## 1. Share the secrets and the database

`dartisan adopt` does this step for you. It reads the Laravel project (and
never changes it), copies `APP_KEY`, the cipher, the `DB_*` settings and the
hashing parameters into this project's `.env`, sets a separate
`CACHE_PREFIX`, and checks the Laravel version, the database driver and the
shared tables:

```bash
dart run bin/dartisan.dart adopt ../shop --check   # report only
dart run bin/dartisan.dart adopt ../shop           # write .env (backup: .env.before-adopt)
```

By hand, the settings are:

```dotenv
# Daravel .env: the same database and the same key as Laravel
APP_KEY=base64:...            # copied from Laravel's .env
DB_CONNECTION=pgsql
DB_HOST=127.0.0.1
DB_DATABASE=shop
DB_USERNAME=shop
DB_PASSWORD=...
AUTH_TOKEN_EXPIRATION=        # minutes; match config('sanctum.expiration')
CACHE_PREFIX=daravel_cache_   # keep cache keys apart (values are not portable)
```

The cipher (`AES-256-CBC`) and the password hasher (bcrypt) already match
Laravel's defaults. Set `APP_CIPHER` or `HASH_DRIVER` only if the Laravel
app changed them. The token's `tokenable_type` stays `App\Models\User`, so a
token issued by Laravel authenticates in Daravel and the other way round.

## 2. Pick one owner for the schema

Both frameworks record migrations in the same `migrations` table. Let one
side own the schema while both run:

- **Laravel owns it** (the usual choice at the start): new tables and
  columns are written as Laravel migrations, and `dartisan migrate` is not
  run against the shared database. Daravel's `bootstrap/migrations.dart`
  still builds the schema for its own tests and local databases, so mirror
  the Laravel tables there. Migration names only match where Daravel uses
  Laravel's (`0001_01_01_000001_create_cache_table`, `..._create_jobs_table`);
  others, such as a `users` migration or the Sanctum migration that
  `php artisan install:api` publishes with a fresh timestamp, would be
  treated as pending and fail on the existing tables. Never run
  `dartisan migrate:fresh` or `migrate:reset` there: they drop or roll back
  Laravel's tables too.
- **Daravel owns it** (once most of the code has moved): port the remaining
  migrations to `bootstrap/migrations.dart` with the same names and stop
  running `php artisan migrate`.

## 3. Port one endpoint

Take a read-only endpoint first. Keep the URI, the route name and the
response shape:

```php
// Laravel: routes/api.php
Route::get('/orders/{order}', [OrderController::class, 'show'])
    ->middleware('auth:sanctum')->name('orders.show');
```

```dart
// Daravel: routes/api.dart
router
    .get('/orders/{order}', orders.show)
    .name('orders.show')
    .middleware(const ['auth'])
    .returns(OrderResource.schema, name: 'Order');
```

Error bodies (401, 403, 404, 422, 429), pagination and resource JSON are
Laravel's, so clients cannot tell which side answered. To check, compare
the two OpenAPI documents (`dartisan openapi:generate` against Scribe or
Scramble output) and run the same requests against both:

```bash
for host in laravel.internal daravel.internal; do
  curl -s -H "Authorization: Bearer $TOKEN" "http://$host/api/orders/42" | jq -S . > "$host.json"
done
diff laravel.internal.json daravel.internal.json
```

In Daravel's tests, the matchers from `package:daravel_test/conformance.dart`
assert the Laravel shapes directly.

## 4. Route it at the proxy

### Caddy

```caddyfile
api.example.com {
	# Endpoints already served by Daravel
	@daravel path /api/orders /api/orders/* /api/reports/*
	handle @daravel {
		reverse_proxy 127.0.0.1:8000
	}

	# Everything else stays on Laravel
	handle {
		root * /var/www/shop/public
		php_fastcgi unix//run/php/php8.3-fpm.sock
		file_server
	}
}
```

### nginx

```nginx
upstream daravel { server 127.0.0.1:8000; keepalive 32; }

server {
    listen 443 ssl http2;
    server_name api.example.com;
    root /var/www/shop/public;

    # Endpoints already served by Daravel
    location ~ ^/api/(orders|reports)(/|$) {
        proxy_pass http://daravel;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    # Everything else stays on Laravel
    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }
    location ~ \.php$ {
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
    }
}
```

Trust the proxy in Daravel so client IPs (rate limits, logs) and the scheme
come from `X-Forwarded-*`:

```dart
TrustProxiesMiddleware(proxies: ['127.0.0.1/32'])
```

Route by exact path segments, not by prefix strings: `/api/orders*` would
also catch `/api/orders-archive`. Both frameworks have a `/up` health
route; let monitoring call each application on its own port.

Rolling back an endpoint is a one-line change in the proxy, because both
applications keep working on the same data.

## 5. Background work

- **Queues.** Both sides can use the `jobs` table, but each runs only its own
  jobs. Daravel workers skip Laravel jobs without touching them. Laravel
  workers would fail Daravel jobs, so give Daravel its own queue names
  (`Queue.dispatch(job).onQueue('daravel')`, `dartisan queue:work
  --queue=daravel`).
- **Scheduler.** Move a scheduled task by removing it from
  `routes/console.php` and adding it to Daravel's schedule in the same
  deploy, so it never runs twice.
- **Cache.** Laravel stores PHP-serialized values, Daravel JSON. Keep the
  prefixes apart (step 1).

## 6. Finish

When the proxy sends nothing to Laravel any more, make Daravel the schema
owner (step 2: give its migrations Laravel's recorded names, or insert
the matching rows), move the scheduler and queue workers, and remove the
`handle` / `location` block for Laravel. See [Deployment](deployment.md) for
running Daravel on its own.
