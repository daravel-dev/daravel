# Releases and versioning

Daravel is in its `1.0.0` beta. The four packages (`daravel`, `dartisan_cli`,
`daravel_test`, `daravel_lints`) are released together under one version,
published on [pub.dev](https://pub.dev/packages/daravel) by the verified
publisher `daravel.teoprayoga.my.id`.

| Version | Highlights |
| :-- | :-- |
| `1.0.0-beta.3` | Route metadata (`.validates()`, `.returns()`) and OpenAPI schemas, typed request input, `.env.encrypted`, `dartisan adopt`, embedded queue and scheduler, faster request path |
| `1.0.0-beta.2` | `dartisan` delegation, welcome page, Laravel queue guard, `PORT` fallback |
| `1.0.0-beta.1` | First public release: the complete Tier 1 framework |

The full notes are in the
[changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md)
and on the [GitHub releases](https://github.com/daravel-dev/daravel/releases)
page.

## What a beta means

- The Laravel-facing formats (error and pagination JSON, Sanctum tokens,
  bcrypt hashes, `Crypt` payloads, shared tables) are locked by the
  conformance suite. They change only to match Laravel more closely, and the
  changelog says so.
- The Dart API may still change before `1.0.0`. Breaking changes are listed
  under "Changed" in the changelog.

## Branches

Like Laravel, Daravel keeps one branch per major version. `main` is where
development happens; `1.x` follows the latest `1.x` release. These docs exist
for both: `1.x` is the default, `main` describes unreleased work.
