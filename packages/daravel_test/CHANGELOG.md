# Changelog

## 1.0.0

- Requires `daravel` 1.0.0.
- `TestClient.post`, `put`, `patch` and `send` take `files:` (uploads built with `UploadedFile.fake`).

## 1.0.0-beta.3

- Requires `daravel` 1.0.0-beta.3; no API changes.

## 1.0.0-beta.2

- Requires `daravel` 1.0.0-beta.2; doc comment fixes for `assertSoftDeleted` / `assertNotSoftDeleted`.

## 1.0.0-beta.1

First public beta: `TestClient` and `TestResponse` assertions, `refreshDatabase` and database assertions, time travel, architecture checks, and Laravel 12 conformance contracts (`package:daravel_test/conformance.dart`).

The full history of the Daravel workspace is in the
[repository changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).
