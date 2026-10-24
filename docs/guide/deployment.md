# Deployment

## Native bundle

```bash
dart run bin/dartisan.dart build             # → build/server/bundle
dart run bin/dartisan.dart build --with-cli  # also bin/dartisan in the bundle
```

`dartisan build` runs `dart build cli`, which compiles AOT and runs build
hooks: SQLite is downloaded (hash-verified) and placed in `bundle/lib/`.
Copy the whole `bundle/` directory to the server and start `bin/server`.
(`dart compile exe` cannot be used: it refuses packages with build hooks.)

## Docker

`dartisan build --docker` writes a multi-stage `Dockerfile` (Dart SDK
builder, `debian:bookworm-slim` runtime, non-root user, no system SQLite
needed) and `.dockerignore`. The `api` template also ships
`docker-compose.yml` with PostgreSQL 16. The reference app in this repository ships the same
runtime stage in `apps/daravel_starter/Dockerfile`, built from the repository
root (`docker build -f apps/daravel_starter/Dockerfile .`) because it is part
of the pub workspace.

## Ports and container platforms

The server listens on `APP_HOST:APP_PORT` (`127.0.0.1:8000` by default). On
Cloud Run, Railway, Render, Fly.io and similar platforms, which inject a
`PORT` variable, Daravel uses that port when `APP_PORT` is not set and then
binds `0.0.0.0` so the platform can reach it; the generated `Dockerfile` sets
`PORT=8080` as a default the platform can override. `SIGTERM` drains
in-flight requests within `SHUTDOWN_TIMEOUT`.

## Concurrency

`APP_ISOLATES=N` (or `serve --isolates=N`) starts a supervisor and N worker
isolates sharing one port. Per-process state (rate limits, the `process`
cache store, locks, metrics) goes through the coordinator. Start with one
isolate per vCPU and measure (see [Performance](performance.md)).
SQLite `:memory:` cannot be shared between isolates; use a file or
PostgreSQL.

## Topology

Run Daravel behind a reverse proxy (Caddy, nginx) that terminates TLS and
compresses responses, and trust that proxy explicitly:

```dart
TrustProxiesMiddleware(proxies: ['10.0.0.0/8'])
```

Without it, `X-Forwarded-*` headers are ignored.

## Secrets: encrypted environment files

`dartisan env:encrypt` writes `.env.encrypted` (or `.env.production.encrypted`
with `--env=production`) in the format of `php artisan env:encrypt`, so either
framework can read the file the other wrote. The encrypted file can be
committed; the key stays in your secret manager:

```bash
dart run bin/dartisan.dart env:encrypt --env=production   # prints a new key
dart run bin/dartisan.dart env:encrypt --readable         # names stay visible in diffs
dart run bin/dartisan.dart env:decrypt --key=base64:...   # back to .env
```

At runtime, set `DARAVEL_ENV_ENCRYPTION_KEY` (or `LARAVEL_ENV_ENCRYPTION_KEY`)
and the application decrypts `.env.encrypted` and `.env.{APP_ENV}.encrypted`
in memory at boot; no plain `.env` is written to disk. The generated
`.dockerignore` lets encrypted files into the image. A wrong key stops the
boot with a clear error, and `dartisan doctor` warns when an encrypted file
has no key.

`dartisan env:obfuscate --only=API_TOKEN` writes a Dart class whose values are
XOR-masked, so they do not show up in `strings bin/server` (useful for keys
compiled into a client). This is obfuscation, not encryption: the mask ships
in the same binary, so it does not replace `env:encrypt` for real secrets.

## One process: embedded queue and scheduler

Small deployments (one VPS, one container) can run HTTP, a queue worker and
the scheduler in one process:

```bash
dart run bin/dartisan.dart serve --embed-queue --embed-scheduler
SERVER_EMBED_QUEUE=true SERVER_EMBED_SCHEDULER=true bin/server   # same, from the bundle
```

The queue worker (on `SERVER_EMBED_QUEUES`, default the default queue) and
the scheduler each run in their own isolate, so jobs never block the HTTP
event loop. A crashed isolate is respawned; on `SIGTERM` the current job or
tick finishes before the process exits. Scheduled console commands run when
the server is started with `dartisan serve`; started as `bin/server`, the
embedded scheduler runs jobs, closures and `exec` tasks. Embedding needs a
file or PostgreSQL database (an in-memory SQLite database is refused). For
several instances, keep one embedded scheduler (or run `schedule:work`
separately) and scale queue workers on their own.

## Google Cloud Run

The generated `Dockerfile` runs on Cloud Run unchanged: it listens on the
injected `PORT`, logs JSON to stdout (Cloud Logging parses it) and ships
`bin/dartisan` next to `bin/server` for one-off commands.

```bash
REGION=asia-southeast2
IMAGE=$REGION-docker.pkg.dev/$PROJECT/daravel/api:$(git rev-parse --short HEAD)
SQL=$PROJECT:$REGION:main          # Cloud SQL for PostgreSQL instance

gcloud artifacts repositories create daravel --repository-format=docker --location=$REGION
gcloud builds submit --tag $IMAGE

# Secrets once: the APP_KEY from `dartisan key:generate --show` and the DB password
printf '%s' 'base64:...' | gcloud secrets create app-key --data-file=-
printf '%s' '...'        | gcloud secrets create db-password --data-file=-

gcloud run deploy api --image $IMAGE --region $REGION \
  --add-cloudsql-instances $SQL \
  --set-env-vars "DB_CONNECTION=pgsql,DB_HOST=/cloudsql/$SQL,DB_DATABASE=app,DB_USERNAME=app,APP_ISOLATES=2,DB_POOL_SIZE=5,SHUTDOWN_TIMEOUT=8s,QUEUE_CONNECTION=database" \
  --set-secrets "APP_KEY=app-key:latest,DB_PASSWORD=db-password:latest" \
  --cpu 2 --memory 512Mi --concurrency 200
```

- **Cloud SQL.** `--add-cloudsql-instances` mounts the instance's Unix socket
  under `/cloudsql/`; `DB_HOST` set to that directory connects through it
  (as in Laravel). Keep `DB_SSLMODE=disable` for the socket; with a private
  IP instead, set `DB_HOST` to the IP and `DB_SSLMODE=require`.
- **Connections.** Each isolate has its own pool, so the database sees up to
  `instances × APP_ISOLATES × DB_POOL_SIZE` connections. Cap
  `--max-instances` to fit the instance's `max_connections`.
- **Isolates.** Match `APP_ISOLATES` to `--cpu`.
- **Shutdown.** Cloud Run sends `SIGTERM` and kills the container 10 seconds
  later; `SHUTDOWN_TIMEOUT=8s` drains in-flight requests inside that window.
- **Probes.** Point the startup probe at `/up/ready` (it checks the
  database) and the liveness probe at `/up`, in the service YAML or the
  console.

Migrations run as a Cloud Run job from the same image, before traffic moves
to the new revision:

```bash
gcloud run jobs deploy migrate --image $IMAGE --region $REGION \
  --set-cloudsql-instances $SQL \
  --set-env-vars "DB_CONNECTION=pgsql,DB_HOST=/cloudsql/$SQL,DB_DATABASE=app,DB_USERNAME=app" \
  --set-secrets "APP_KEY=app-key:latest,DB_PASSWORD=db-password:latest" \
  --command /app/bin/dartisan --args migrate
gcloud run jobs execute migrate --region $REGION --wait
```

Cloud Run services only run while they handle requests, so background work
goes to jobs started by Cloud Scheduler, built the same way: the scheduler
as `--args schedule:run` every minute, and queue workers as
`--args queue:work,--stop-when-empty,--max-time=540` every few minutes. For
a steady queue, run `queue:work` on a VM instead (next section).

## VPS with systemd and Caddy

Build the bundle on a machine with the same OS and CPU architecture as the
server (or in CI), with `bin/dartisan` included:

```bash
dart run bin/dartisan.dart build --with-cli
RELEASE=/srv/api/releases/$(date +%Y%m%d%H%M%S)
rsync -a build/server/bundle/ deploy@vps:$RELEASE/
ssh deploy@vps "cd $RELEASE && ln -s /srv/api/shared/.env .env \
  && ln -s /srv/api/shared/storage storage \
  && ./bin/dartisan migrate && ./bin/dartisan doctor --production \
  && ln -sfn $RELEASE /srv/api/current \
  && sudo systemctl restart api api-queue api-schedule"
```

The application reads `.env` from its working directory, so each release
links the shared `.env` and `storage/`. Rolling back means pointing
`current` at the previous release and restarting.

`/etc/systemd/system/api.service`:

```ini
[Unit]
Description=Daravel API
After=network-online.target postgresql.service
Wants=network-online.target

[Service]
User=daravel
WorkingDirectory=/srv/api/current
ExecStart=/srv/api/current/bin/server
Environment=APP_ISOLATES=4 SHUTDOWN_TIMEOUT=25s
Restart=always
RestartSec=2
KillSignal=SIGTERM
TimeoutStopSec=30
NoNewPrivileges=true
ProtectSystem=strict
ReadWritePaths=/srv/api/shared/storage
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

The workers are the same unit with another command; both stop cleanly on
`SIGTERM` after the current job:

```ini
# /etc/systemd/system/api-queue.service ([Unit]/[Install] as above)
[Service]
User=daravel
WorkingDirectory=/srv/api/current
ExecStart=/srv/api/current/bin/dartisan queue:work --max-time=3600
Restart=always
TimeoutStopSec=90

# /etc/systemd/system/api-schedule.service
[Service]
User=daravel
WorkingDirectory=/srv/api/current
ExecStart=/srv/api/current/bin/dartisan schedule:work
Restart=always
```

`--max-time` restarts the queue worker every hour, and `dartisan
queue:restart` asks running workers to exit after their current job (for
example at the end of a deploy). Set `TimeoutStopSec` above the longest job.

Caddy terminates TLS (certificates are automatic) and compresses responses.
`/etc/caddy/Caddyfile`:

```caddyfile
api.example.com {
	encode zstd gzip
	reverse_proxy 127.0.0.1:8000 {
		health_uri /up
	}
}
```

Keep `APP_HOST=127.0.0.1` (the default) so the server is only reachable
through Caddy, and trust it with `TrustProxiesMiddleware(proxies:
['127.0.0.1/32'])`. To move a Laravel application over endpoint by endpoint
behind the same Caddy, see [Migrating from Laravel](migrating-from-laravel.md).

## Production checklist

- `APP_ENV=production`, `APP_DEBUG=false` (boot fails otherwise unless
  explicitly allowed), a 32-byte `APP_KEY` from a secret manager.
- `dart run bin/dartisan.dart doctor --production` checks configuration,
  database reachability, public `/metrics`, `QUEUE_CONNECTION=sync` and
  more; run it in the container entrypoint.
- Health endpoints: `/up` (liveness) and `/up/ready` (readiness).
- Run `queue:work` and `schedule:work` as separate processes.
- Logs: `LOG_STACK=json` for structured logs; secrets are redacted.
