# Changelog

## Unreleased

- Added `LIBSODIUM_STRICT_PAYLOAD` (`TeobiefyConfig.strictPayload`, off): clear keys sent beside `data_enc` are dropped (the Laravel application merges them) and a clear body from a client that holds a session is `406`.

- Fixed: a replayed request is `406` (each session's nonces are remembered for its TTL: `TeobiefySessions.useNonce`), a clear body from a client with no key is `409 SESSION_KEY_REQUIRED` before the handler runs, and a presented session id the store does not know is `409` even with the legacy key.

## 1.13.0

- First release: teobiefy's protocol v1 (Bali Melajah's encrypted API payloads). `Teobiefy.handshake` (X25519 `crypto_kx` session keys, checked against libsodium), `TeobiefySessions` (cache-backed, sliding TTL, the Laravel cache key), the `teobiefy` middleware (ChaCha20-Poly1305 IETF requests and responses, zstd-framed `data`, `409 SESSION_KEY_REQUIRED`, `406 Invalid payload`), `withTeobiefy()` with Laravel's `LIBSODIUM_*` settings.
