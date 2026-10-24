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
`docker-compose.yml` with PostgreSQL 16.

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

## Production checklist

- `APP_ENV=production`, `APP_DEBUG=false` (boot fails otherwise unless
  explicitly allowed), a 32-byte `APP_KEY` from a secret manager.
- `dart run bin/dartisan.dart doctor --production` checks configuration,
  database reachability, public `/metrics`, `QUEUE_CONNECTION=sync` and
  more; run it in the container entrypoint.
- Health endpoints: `/up` (liveness) and `/up/ready` (readiness).
- Run `queue:work` and `schedule:work` as separate processes.
- Logs: `LOG_STACK=json` for structured logs; secrets are redacted.
