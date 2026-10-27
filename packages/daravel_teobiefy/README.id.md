<!-- source: README.md sha256:2ac503b9b37b -->
<img src="https://raw.githubusercontent.com/daravel-dev/daravel/main/docs/brand/png/daravel-icon-128.png" alt="Daravel" width="64" align="right">

# daravel_teobiefy

[English](https://github.com/daravel-dev/daravel/blob/main/packages/daravel_teobiefy/README.md) · Bahasa Indonesia

Payload API terenkripsi untuk [Daravel](https://pub.dev/packages/daravel),
kompatibel dengan API Laravel Bali Melajah (teobiefy, protokol v1): client
web dan mobile-nya bisa berkomunikasi dengan backend Daravel tanpa
perubahan. Handshake X25519 (`crypto_kx` dari libsodium) memberi setiap
client sepasang kunci sesi; payload disegel dengan ChaCha20-Poly1305 IETF.

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

- Pertukaran kunci dan cipher-nya dicek terhadap vector buatan libsodium
  (sodium PHP); frame zstd-nya dicek dengan `zstd` referensi.
- Tanpa sesi, jawabannya `409 SESSION_KEY_REQUIRED`, tidak pernah data
  polos.
- Sesi tetap berlaku di beberapa worker isolate (store cache `process` bila
  store default menyimpan salinan per isolate).

Dokumentasi: <https://github.com/daravel-dev/daravel/blob/main/docs/guide/id/teobiefy.md>.

## Lisensi dan merek dagang

MIT. "Laravel" adalah merek dagang Laravel Holdings Inc.; "Dart" adalah
merek dagang Google LLC. Daravel adalah proyek independen, tidak berafiliasi
dengan atau didukung oleh mereka.
