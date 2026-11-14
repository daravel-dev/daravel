### Added

- `redactUrlPassword(url, {loneUserIsPassword})`: a URL with the password in its user info masked, for messages and logs; it needs no valid URL. `ConnectionConfig.redactUrl`, Redis and the upstream proxy use it.

### Fixed

- Security: a database URL's password could reach an error message, the boot log or `doctor`'s output. `ConnectionConfig.redactUrl` masked it only for a lower-case scheme without `+` and a password without `@` or `/`, and a malformed `DB_URL` (`postgres://app:secret@[::1/db`) failed in `withUrl` with `Uri.parse`'s own error, which quotes the whole URL. `redactUrl` no longer needs a valid URL: everything between `scheme://user:` and the last `@` is masked, whatever the scheme. `withUrl`, `fromUrl` and `DB_URL` throw a `FormatException` that quotes the URL only redacted, also for a malformed percent-encoding. Since 1.0.0.
- Security: a malformed `REDIS_URL` (`daravel_redis`) or `UPSTREAM_URL` failed with `Uri.parse`'s own error, password included. Both now name the URL only redacted; for Redis a lone `secret@` counts as the password, as Redis reads it.

### Upgrade notes

- Upgrading can change the error a malformed `REDIS_URL` throws: a `ConfigException` (as other bad Redis settings already did) instead of a `FormatException` or `ArgumentError`; a malformed `UPSTREAM_URL` throws a `ConfigException` too. New public name: `redactUrlPassword`.
