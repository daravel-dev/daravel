# Changelog

## 1.13.0

- First release: teobiefy's protocol v1 (Bali Melajah's encrypted API payloads). `Teobiefy.handshake` (X25519 `crypto_kx` session keys, checked against libsodium), `TeobiefySessions` (cache-backed, sliding TTL, the Laravel cache key), the `teobiefy` middleware (ChaCha20-Poly1305 IETF requests and responses, zstd-framed `data`, `409 SESSION_KEY_REQUIRED`, `406 Invalid payload`), `withTeobiefy()` with Laravel's `LIBSODIUM_*` settings.
