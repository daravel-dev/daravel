### Fixed

- PostgreSQL: `DB_SSLMODE=verify-ca` (and any other value starting with `verify`, such as a misspelt `verify-full`) turned TLS off without a word; it now verifies the certificate and the host name, as `verify-full` (the `postgres` package has no chain-only check), with a warning at boot. `prefer`, `allow` and other unknown values still connect without TLS, now with a warning at boot that names the value and suggests `require` or `verify-full`. Modes are read in any case, with `-` or `_` (`REQUIRE`, `verify_full`).

### Added

- `PostgresDriver.sslModeOf` shows how a `DB_SSLMODE` maps; `PostgresDriver.fromConfig` takes `onWarning` (standard error by default).

### Upgrade notes

- PostgreSQL with `DB_SSLMODE=verify-ca`: the connection was not encrypted before; it is now encrypted and verified, so it fails at boot when the server certificate does not chain to a trusted root or does not name `DB_HOST`. Set `DB_SSLMODE=require` for encryption without checks, or fix the certificate.
- `DB_SSLMODE=REQUIRE` (upper case) and `verify_full` were read as `disable`; they now mean what they say.
