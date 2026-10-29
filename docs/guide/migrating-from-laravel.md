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

- **The same database server.** Daravel runs on MySQL, MariaDB, PostgreSQL
  and SQLite, so it can use the Laravel application's database as it is.
- **API with bearer tokens.** Sanctum personal access tokens work on both
  sides. Session cookies and CSRF are shared with [daravel_session](sessions.md)
  (same `APP_KEY` and store); Sanctum's stateful SPA mode is not, so routes
  that depend on it stay in Laravel.
- **Laravel 10 to 13** formats out of the box; the [conformance suite](laravel-coexistence.md)
  pins Laravel 13 and Sanctum 4. Laravel 8 and 9 applications set
  `COMPAT_LARAVEL_VERSION` (see the end of this page).

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
### Or Daravel in front

Without a proxy of your own, Daravel can stand in front of Laravel: what it
has a route for, it answers; everything else, whatever the method, it
forwards to Laravel.

```dart
Application.configure(basePath: basePath)
    .withUpstream(url: 'http://127.0.0.1:8080')   // or UPSTREAM_URL in .env
    // ...
```

A new route in Daravel takes over that method and path at the next deploy,
with no proxy configuration to change. A `GET /api/orders` in Daravel does
not turn a `POST /api/orders` into a 405: it still goes to Laravel. Bodies
stream both ways (uploads and downloads are not held in memory), redirects,
cookies (every `Set-Cookie`) and compressed bodies pass through as they
are, and `X-Powered-By` is removed. Laravel receives the client's address in
`X-Forwarded-For`, `-Proto`, `-Host` and `-Port`, so trust Daravel in its
`TrustProxies` middleware (`$middleware->trustProxies(at: '127.0.0.1')`).
If Laravel does not answer, the client gets 502; if it is too slow
(`timeout:`, 60 seconds), 504. WebSockets are not forwarded.

### Progress

`dartisan route:diff` compares Laravel's routes with Daravel's: which ones
Daravel answers, which ones still go to Laravel, and which ones exist only
in Daravel. Parameter names do not matter (`{order}` matches `{id}`).

```bash
dart run bin/dartisan.dart route:diff --laravel=/var/www/shop     # runs php artisan route:list --json
dart run bin/dartisan.dart route:diff --laravel-json=routes.json  # its saved output
dart run bin/dartisan.dart route:diff --laravel=/var/www/shop --json
```

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

## Laravel 8 and 9 applications

Everything above applies; four things differ for an application that was
never upgraded to Laravel 10 or later, learned from a real port of a
Laravel 8.83 application on MariaDB:

- **Error bodies.** Set `COMPAT_LARAVEL_VERSION=8` (or `9`) so validation
  messages, the 422 summary and the 404/405 messages match what the
  application's clients already parse ([Laravel coexistence](laravel-coexistence.md#older-laravel-versions)).
- **MySQL strict mode.** Laravel sets `sql_mode` on every connection;
  `'strict' => false` in the old `config/database.php` lets inserts without
  every `NOT NULL` value through. Mirror it with `DB_STRICT=false` (or
  `DB_SQL_MODES`), or MariaDB's default strict mode rejects rows the
  Laravel application accepts ([Database](database.md)).
- **State kept in statics.** PHP forgets everything between requests, so a
  port tends to keep what Laravel put in `Cache::remember`, a rate limiter
  or a JWT blacklist in a static field. Each worker isolate has its own
  copy of a static, and it is gone after a restart. Use the same shared
  stores Laravel used:

  ```dart
  // Laravel: Cache::remember('config.is_sqd', 600, fn () => ...)
  final isSqd = await Cache.remember<bool>(
    'config.is_sqd',
    const Duration(minutes: 10),
    () => Setting.query().where('key', 'is_sqd').exists(),
  );
  // Laravel: RateLimiter::tooManyAttempts('places:'.$ip, 5)
  final limiter = App.make<RateLimiter>();
  // Laravel: JWTAuth::invalidate($token) -> cache blacklist
  await Auth.jwtGuard().invalidate(token);
  ```

  With `CACHE_STORE=database` (Laravel's `cache` table) the values survive
  restarts and reach the scheduler, as Laravel's file cache did;
  `dartisan lint` reports statics that collect state
  (`no_mutable_static_in_app`).
- **Encrypted response envelopes.** Applications that wrap JSON in
  `openssl_encrypt(..., 'aes-256-cbc')` with a static key keep working with
  `daravel_teobiefy`'s AES-CBC mode ([teobiefy](teobiefy.md)); new
  endpoints should use its X25519 protocol instead.

## The application model (daragic)

`dartisan daragic:export` writes the application's structure as a DAM
(Daravel Application Model), the language-neutral format the `daragic`
generator reads in either direction:

```bash
dart run bin/dartisan.dart daragic:export                         # dam/dam.json + dam/daragic.lock
dart run bin/dartisan.dart daragic:export --only=routes,models --out=build/dam
```

It boots the application (without serving) and records the routes (methods,
URI in Laravel's form, name, controller action from `.action()`,
middleware, `where` patterns, validation rules both as the DSL and
structured, the documented response), the models from `bootstrap/models.dart`
(table, key, fillable, casts, hidden, relations with their keys, as
`App\Models\...` classes), migrations with their batch, the database schema,
the schedule, jobs, feature flags, translations, middleware and the keys of
`.env.example`. The file is deterministic (sorted, no timestamps), so two
exports diff cleanly, and holds no secrets: keys that look secret
(`*_KEY`, `*_PASSWORD`, `*_TOKEN`, ...) keep no default. `daragic.lock`
hashes each section and entity for incremental merges.

Method bodies (controllers, closures, jobs, scopes) are not exported yet:
they need the Dialect IR extractor. Routes registered without `.action()`
appear as closures. `report.unsupported` in the file lists what is left out,
so nothing is dropped silently.
