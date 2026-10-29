/// teobiefy for Daravel: teobiefy's encrypted payloads (protocol v1), as a
/// Laravel API implements them, so that API's clients talk to a Daravel
/// backend unchanged.
/// An X25519 handshake (`crypto_kx`) gives each client a pair of session
/// keys; request and response payloads are sealed with ChaCha20-Poly1305
/// IETF, as libsodium does.
///
/// ```dart
/// Application.configure(basePath: '.').withTeobiefy()
/// ```
///
/// For an API ported from Laravel whose clients open an OpenSSL
/// AES-256-CBC `{data_enc, iv}` envelope with a static key, there is
/// [TeobiefyAesCbc] and the `teobiefy.aes` middleware
/// (`withTeobiefyAesCbc()`): legacy compatibility, without a MAC.
library;

export 'src/aes_cbc.dart';
export 'src/crypto.dart';
export 'src/middleware.dart';
export 'src/sessions.dart';
export 'src/setup.dart';
