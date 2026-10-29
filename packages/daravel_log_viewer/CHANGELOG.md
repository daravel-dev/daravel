# Changelog

## 1.18.0

- Version aligned with Daravel 1.18.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.17.0

- Version aligned with Daravel 1.17.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.16.0

- Version aligned with Daravel 1.16.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.15.0

- First release: `withLogViewer(path:, middleware:)` serves a log viewer page and its JSON API (files, entries, a server-sent-events tail, download, opt-in delete). `ReverseLogReader` reads Daravel's JSON logs and Laravel's Monolog files from their end in constant memory (pages with a byte cursor, a scan limit, a polling tail that survives rotation); `PathGuard` opens only `.log` files of the folder; `Masker` hides secret values in context and text; a nonce-based Content-Security-Policy, no external assets, and 403 outside local without middleware. The `LOG_VIEWER_*` settings.
