### Fixed

- Security: a personal access token whose `abilities` column is `NULL`, empty or not a JSON list of strings has no ability (`PersonalAccessToken.abilitiesOf`), where `NULL` or an empty value read as every ability (`["*"]`); elements that are not strings are left out, and a row with a `NULL` name, owner type or hash reads without an error. Daravel and Sanctum always write a JSON list (`["*"]` for every ability).
- Security: `JwtGuard.invalidate(token)` verifies the token's signature against the key ring before revoking its `jti` (an expired but signed token may still be revoked; `JwtCodec.verify(token, checkTimes: false)`), and throws `JwtException` for a `jti` that is not a string or an `exp` no date holds. Before, it read the `jti` of the token unverified, so a forged token could revoke someone else's.
- A JWT whose `kid`, `jti` or `iss` is not a string, or whose `exp`, `nbf` or `iat` no date holds (`1e308`), is refused with `JwtException` (a `401`) instead of a type error (a `500`); the `JwtClaims` getters return null for such values and never throw.

### Upgrade notes

- Upgrading can change what a personal access token may do: a row whose `abilities` is `NULL` or empty, which only another writer than Daravel or Sanctum could have left, now has no ability instead of every one. Give such tokens `["*"]` (`UPDATE personal_access_tokens SET abilities = '["*"]' WHERE abilities IS NULL OR abilities = ''`) if they should keep it.
