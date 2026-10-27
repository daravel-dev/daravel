<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_teobiefy

English · [Bahasa Indonesia](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_teobiefy/README.id.md)

Encrypted API payloads for [Daravel](https://pub.dev/packages/daravel),
compatible with Bali Melajah's Laravel API (teobiefy, protocol v1): its web
and mobile clients talk to a Daravel backend unchanged. An X25519 handshake
(libsodium's `crypto_kx`) gives each client a pair of session keys;
payloads are sealed with ChaCha20-Poly1305 IETF.

```bash
dart pub add daravel_teobiefy
```

```dart
Application.configure(basePath: '.').withTeobiefy() // LIBSODIUM_SESSION_TTL, ...

router.post('/api/v1/session-key', Teobiefy.handshake)
    .middleware(const ['throttle:30,1']);

router.group(middleware: const ['teobiefy'], (r) {
  r.get('/api/profile', ProfileController.show); // `data` leaves encrypted
});
```

- The key exchange and the cipher are checked against vectors made by
  libsodium (PHP's sodium); the zstd frames against the reference `zstd`.
- No session means `409 SESSION_KEY_REQUIRED`, never plain data.
- Sessions survive several worker isolates (the `process` cache store when
  the default keeps a copy per isolate).

Documentation: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/teobiefy.md>.

## License and trademarks

MIT. "Laravel" is a trademark of Laravel Holdings Inc.; "Dart" is a
trademark of Google LLC. Daravel is an independent project, not affiliated
with or endorsed by any of them.
