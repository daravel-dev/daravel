# Changelog

## 1.0.0-beta.2

- `daravelLogoDataUri` and `daravelFaviconDataUri` for welcome pages.
- `ServeOptions` falls back to the platform `PORT` (Cloud Run, Railway, Render, Fly.io) and binds `0.0.0.0` when `APP_PORT` is unset.
- `DatabaseQueue` skips jobs pushed by a Laravel app sharing the `jobs` table instead of failing them (or crashing on Laravel's string `backoff`).

## 1.0.0-beta.1

First public beta: the complete Tier 1 framework (container and zones, HTTP kernel and routing, validation with Laravel's rules and messages, query builder, ORM, migrations, auth with Sanctum-compatible tokens and JWT, multi-isolate serving, cache and rate limiting, events, queues and scheduling, API resources, storage, logging and metrics), Laravel-compatible wire and storage formats locked by a conformance suite, a security regression suite, and the `Str` / helpers / collection support layer.

The full history of the Daravel workspace is in the
[repository changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).
