# Changelog

## 1.20.0

- Version aligned with Daravel 1.20.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.19.1

- Version aligned with Daravel 1.19.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.19.0

- Added `teobiefy.aes:php` and `TeobiefyAesCbc.encrypt(phpJson:)` / `seal(phpJson:)`: PHP `json_encode` bytes inside and outside the envelope.

## 1.18.1

- Version aligned with Daravel 1.18.1; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.18.0

- Added the OpenSSL envelope of a Laravel API that encrypts responses with `openssl_encrypt` instead of libsodium: `TeobiefyAesCbc` (`encrypt`/`decrypt` of `{data_enc, iv}`, AES-256-CBC, PKCS#7, a static 32-byte key, a random IV per message), `withTeobiefyAesCbc()` (the key from `OPENSSL_KEY`, `base64:` accepted, checked at boot) and the `teobiefy.aes` middleware for selected routes (`data` of an obiefy envelope by default, `:body` for the whole body, `:decrypt` to open request envelopes, `406 Invalid payload` when one does not open). Checked against NIST SP 800-38A F.2.5 and `openssl enc`. No MAC: legacy compatibility only; new work stays on the X25519 + ChaCha20-Poly1305 protocol.

## 1.17.0

- Version aligned with Daravel 1.17.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.16.0

- Version aligned with Daravel 1.16.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.15.0

- Version aligned with Daravel 1.15.0; see the [changelog](https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md).

## 1.14.0

- Added `LIBSODIUM_STRICT_PAYLOAD` (`TeobiefyConfig.strictPayload`, off): clear keys sent beside `data_enc` are dropped (the Laravel application merges them) and a clear body from a client that holds a session is `406`.

- Fixed: a replayed request is `406` (each session's nonces are remembered for its TTL: `TeobiefySessions.useNonce`), a clear body from a client with no key is `409 SESSION_KEY_REQUIRED` before the handler runs, and a presented session id the store does not know is `409` even with the legacy key.

## 1.13.0

- First release: teobiefy's protocol v1 (encrypted API payloads, as a Laravel API implements them). `Teobiefy.handshake` (X25519 `crypto_kx` session keys, checked against libsodium), `TeobiefySessions` (cache-backed, sliding TTL, the Laravel cache key), the `teobiefy` middleware (ChaCha20-Poly1305 IETF requests and responses, zstd-framed `data`, `409 SESSION_KEY_REQUIRED`, `406 Invalid payload`), `withTeobiefy()` with Laravel's `LIBSODIUM_*` settings.
