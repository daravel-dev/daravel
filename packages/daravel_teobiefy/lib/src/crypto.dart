import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The two keys of a session, from the server's side: [rx] decrypts what
/// the client sends, [tx] encrypts what the server answers (libsodium's
/// `crypto_kx_server_session_keys`).
typedef SessionKeys = ({Uint8List rx, Uint8List tx});

/// libsodium's `crypto_kx` and `crypto_aead_chacha20poly1305_ietf`, the
/// primitives of teobiefy's v1 protocol, in Dart.
abstract final class TeobiefyCrypto {
  static final X25519 _x25519 = X25519();
  static final Blake2b _blake2b = Blake2b();
  static final Chacha20 _aead = Chacha20.poly1305Aead();
  static final Random _random = Random.secure();

  /// A new X25519 key pair for the server's side of a handshake.
  static Future<SimpleKeyPair> newKeyPair() => _x25519.newKeyPair();

  /// The X25519 key pair whose secret key is [secretKey] (32 bytes).
  static Future<SimpleKeyPair> keyPairFrom(List<int> secretKey) =>
      _x25519.newKeyPairFromSeed(secretKey);

  /// libsodium's `crypto_kx_server_session_keys`: with q the X25519 shared
  /// secret, BLAKE2b-512(q ‖ client_pk ‖ server_pk) split in two: the
  /// server's tx is the first half and its rx the second (the client's are
  /// the other way round), as libsodium's kx.c does.
  /// Throws [ArgumentError] for a key that is not 32 bytes or that gives an
  /// all-zero secret (a low-order point), as libsodium refuses it.
  static Future<SessionKeys> serverSessionKeys(
    SimpleKeyPair server,
    List<int> clientPublicKey,
  ) async {
    if (clientPublicKey.length != 32) {
      throw ArgumentError.value(
        clientPublicKey.length,
        'clientPublicKey',
        'must be 32 bytes',
      );
    }
    final shared = await (await _x25519.sharedSecretKey(
      keyPair: server,
      remotePublicKey: SimplePublicKey(
        clientPublicKey,
        type: KeyPairType.x25519,
      ),
    )).extractBytes();
    if (shared.every((b) => b == 0)) {
      throw ArgumentError('The client public key is a low-order point.');
    }
    final serverPublicKey = (await server.extractPublicKey()).bytes;
    final hash = (await _blake2b.hash([
      ...shared,
      ...clientPublicKey,
      ...serverPublicKey,
    ])).bytes;
    return (
      tx: Uint8List.fromList(hash.sublist(0, 32)),
      rx: Uint8List.fromList(hash.sublist(32, 64)),
    );
  }

  /// A random 12-byte nonce, as `random_bytes(12)`.
  static Uint8List nonce() =>
      Uint8List.fromList([for (var i = 0; i < 12; i++) _random.nextInt(256)]);

  /// `crypto_aead_chacha20poly1305_ietf_encrypt($message, '', $nonce,
  /// $key)`: the ciphertext followed by the 16-byte tag.
  static Future<Uint8List> seal(
    List<int> message,
    List<int> key,
    List<int> nonce,
  ) async {
    final box = await _aead.encrypt(
      message,
      secretKey: SecretKey(key),
      nonce: nonce,
    );
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  /// `crypto_aead_chacha20poly1305_ietf_decrypt`; [SecretBoxAuthenticationError]
  /// when the tag does not verify (a wrong key or a tampered message).
  static Future<Uint8List> open(
    List<int> sealed,
    List<int> key,
    List<int> nonce,
  ) async {
    if (sealed.length < 16) {
      throw SecretBoxAuthenticationError();
    }
    final clear = await _aead.decrypt(
      SecretBox(
        sealed.sublist(0, sealed.length - 16),
        nonce: nonce,
        mac: Mac(sealed.sublist(sealed.length - 16)),
      ),
      secretKey: SecretKey(key),
    );
    return Uint8List.fromList(clear);
  }

  /// [data] as a Zstandard frame (RFC 8878) of raw (stored) blocks: any
  /// zstd decoder reads it, `zstd_uncompress` and the browser's included,
  /// without native code here. It is not smaller; the format, not the
  /// compression, is what the v1 clients need.
  static Uint8List zstdFrame(List<int> data) {
    final out = BytesBuilder(copy: false)
      // Magic number, then the frame header descriptor: an 8-byte frame
      // content size (FCS flag 3) and the single segment flag, so no window
      // descriptor; no dictionary, no checksum.
      ..add(const [0x28, 0xB5, 0x2F, 0xFD, 0xE0]);
    final size = ByteData(8)..setUint64(0, data.length, Endian.little);
    out.add(size.buffer.asUint8List());
    const maxBlock = 128 * 1024;
    var offset = 0;
    do {
      final length = min(maxBlock, data.length - offset);
      final last = offset + length >= data.length;
      // Block header (3 bytes, little-endian): last flag, type 0 (raw),
      // size.
      final header = (last ? 1 : 0) | (length << 3);
      out
        ..add([header & 0xFF, (header >> 8) & 0xFF, (header >> 16) & 0xFF])
        ..add(data.sublist(offset, offset + length));
      offset += length;
    } while (offset < data.length);
    return out.takeBytes();
  }

  /// `base64_decode($value, true)`: null unless [value] is strict base64.
  static Uint8List? strictBase64(Object? value) {
    if (value is! String) {
      return null;
    }
    try {
      return base64.decode(value);
    } on FormatException {
      return null;
    }
  }
}
