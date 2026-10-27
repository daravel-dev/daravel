# ADR-024: Laravel's defaults for Crypt and hashing

> Reconstructed from code on 2026-10-27; maintainer to review. The original
> decision is in the maintainer's design documents and review of
> 2026-10-24, which are not public; this record is written from the code,
> its comments and `CHANGELOG.md` only.

## Context

Daravel and Laravel are meant to run side by side on one database and
migrate in either direction. Two formats decide whether that works without
configuration:

- values encrypted with `APP_KEY` (`Crypt`), which either application may
  have to read;
- password hashes in a shared `users` table, which either application may
  have to verify.

Daravel's earlier defaults (AES-256-GCM for `Crypt` and Argon2id for
hashing, from ADR-008) are valid choices, but differ from Laravel's, so a
shared deployment needed both sides configured alike.

## Decision

Use Laravel's defaults, so coexistence needs no configuration:

- **`Crypt` defaults to AES-256-CBC** with HMAC-SHA256, encrypt-then-MAC,
  byte-compatible with Laravel's `aes-256-cbc` payloads
  (`base64(json({iv, value, mac, tag: ""}))`). `APP_CIPHER=AES-256-GCM`
  selects GCM (`{iv, value, mac: "", tag}`, Laravel's `aes-256-gcm`
  shape). Decryption accepts either shape.
- **Hashing defaults to bcrypt** with cost 12, producing `$2y$12$...` like
  PHP's `password_hash()`. `HASH_DRIVER=argon2id` remains available;
  `APP_ENV=testing` lowers the cost, as Laravel's `phpunit.xml` does.
- **`HASH_VERIFY`** still refuses hashes of another driver, except within
  the strong family {bcrypt, argon2id}: legacy or weak formats (pbkdf2)
  cannot be injected as a downgrade, while a bcrypt ⇄ argon2id switch
  still verifies old hashes so `rehashPasswordIfRequired` upgrades them at
  login.

## Consequences

- A Laravel and a Daravel application sharing `APP_KEY` and a database read
  each other's encrypted strings and verify each other's passwords with no
  extra settings. The conformance suite checks the `Crypt` payload against
  one built by Laravel and the bcrypt format.
- `encryptString` / `decryptString` are the cross-runtime calls:
  `encrypt` / `decrypt` JSON-encode values, where Laravel uses PHP's
  `serialize()`.
- Upgrading from the earlier defaults: applications that relied on them
  set `APP_CIPHER=AES-256-GCM` or `HASH_DRIVER=argon2id` explicitly;
  existing Argon2id hashes keep verifying and are rehashed to bcrypt at
  login.
- Hashing still runs in a compute isolate, whichever driver
  ([ADR-004](0004-supervisor-and-workers.md)).

## Sources

- `packages/daravel/lib/src/auth/encryption.dart`
- `packages/daravel/lib/src/auth/hashing.dart`
- `packages/daravel/test/auth/hashing_test.dart`
- `CHANGELOG.md`, "Changed (ADR-024: zero-config Laravel coexistence)"
  under 1.0.0-beta.1
