### Added

- RS256 and JSON Web Key Sets, to verify the tokens of identity providers (Google, Firebase Authentication, Auth0, Okta, Keycloak...). `JwtAlgorithm.rs256` and `RsaJwtKey` (modulus and exponent, or `RsaJwtKey.fromJwk`; at least 2048 bits, RFC 7518 §3.3) verify RSASSA-PKCS1-v1_5 SHA-256 signatures in pure Dart, building the expected encoded message and comparing it whole (RFC 8017 §8.2.2), so no padding is parsed; RS256 keys only verify, and `JwtCodec.sign` refuses them. `JsonWebKeySet.parse`/`fromJson` read a JWKS document (RFC 7517) into RSA and OKP Ed25519 signature keys, skipping encryption keys, other algorithms, symmetric keys and malformed entries, like firebase/php-jwt's `JWK::parseKeySet`. `JwksVerifier` checks a token against a provider's key set like php-jwt's `CachedKeySet`: fetched on first use through `Http`, kept for the response's `Cache-Control: max-age`, fetched again for an unknown `kid` at most once per `refetchInterval` (a minute), one fetch for concurrent verifications, and the keys held kept when a fetch fails; it checks `iss` against a set of issuers, `aud`, the required claims and an optional `validate` callback. `JwksVerifier.firebase(projectId)` applies the Firebase Admin SDK's `verifyIdToken` checks (securetoken keys, `aud`, `iss`, `sub`, `auth_time`) and `JwksVerifier.google(clientId)` those of Google Sign-In ID tokens. Tested with the RFC 7515 A.2 and RFC 8037 A examples.

### Changed

- `JWT_ALGO=RS256` is refused for the JWT guard with a message pointing to `JwksVerifier`: the guard signs its own tokens, with HS256 or EdDSA. Without the check, the new algorithm name would have fallen through to HS256.

### Upgrade notes

- New public names in `package:daravel`: `RsaJwtKey`, `JsonWebKeySet` and `JwksVerifier`, and the enum value `JwtAlgorithm.rs256`. A file that declares one of these names and imports the barrel gets an ambiguous-import error (`hide` them or rename yours); an exhaustive `switch` over `JwtAlgorithm` or over the sealed `JwtKey` needs a case for RS256 / `RsaJwtKey`.
