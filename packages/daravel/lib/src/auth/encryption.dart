import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' as cg;

import '../foundation/exceptions.dart';
import 'hashing.dart' show constantTimeEquals;

/// Symmetric ciphers supported by [Encrypter].
enum EncryptionCipher {
  /// AES-256-GCM (default). Payload `{iv, value, mac: "", tag}` — the same
  /// shape Laravel emits for its `aes-256-gcm` cipher.
  aes256gcm,

  /// AES-256-CBC + HMAC-SHA256 — byte-compatible with Laravel's default
  /// `aes-256-cbc` cipher (`{iv, value, mac, tag: ""}`), for values shared
  /// across a Laravel ⇄ Daravel deployment (BLUEPRINT_V2 §4.4).
  aes256cbc,
}

/// Raised when a payload is malformed, was tampered with or was encrypted
/// with an unknown key.
final class DecryptException extends DaravelException {
  const DecryptException(super.message);
}

/// Raised for invalid keys.
final class EncryptException extends DaravelException {
  const EncryptException(super.message);
}

/// Authenticated symmetric encryption keyed by `APP_KEY` (§7.6.1).
///
/// Payloads are `base64(json({"iv","value","mac","tag"}))` like Laravel's,
/// so [encryptString] output can be read by a Laravel app sharing the key
/// (either cipher; decryption picks the cipher from the payload).
/// [encrypt]/[decrypt] JSON-encode arbitrary values, where Laravel uses PHP
/// `serialize()`, so only the string variants are cross-runtime.
final class Encrypter {
  Encrypter(
    List<int> key, {
    List<List<int>> previousKeys = const <List<int>>[],
    this.cipher = EncryptionCipher.aes256gcm,
  }) : _keys = <List<int>>[key, ...previousKeys] {
    for (final k in _keys) {
      if (k.length != 32) {
        throw EncryptException(
          'Encryption keys must be 32 bytes for AES-256; got ${k.length}.',
        );
      }
    }
  }

  /// Builds an encrypter from `APP_KEY` (`base64:...`) and optional
  /// `APP_PREVIOUS_KEYS` (comma separated) for graceful key rotation.
  factory Encrypter.fromAppKey(
    String appKey, {
    Iterable<String> previousKeys = const <String>[],
    EncryptionCipher cipher = EncryptionCipher.aes256gcm,
  }) => Encrypter(
    parseKey(appKey),
    previousKeys: previousKeys
        .where((k) => k.trim().isNotEmpty)
        .map(parseKey)
        .toList(),
    cipher: cipher,
  );

  final List<List<int>> _keys;
  final EncryptionCipher cipher;

  /// The active (first) key.
  List<int> get key => _keys.first;

  /// Decodes `base64:<key>` (or raw base64) into bytes.
  static List<int> parseKey(String value) {
    final raw = value.startsWith('base64:') ? value.substring(7) : value;
    try {
      return base64.decode(raw.trim());
    } on FormatException {
      throw const EncryptException(
        'APP_KEY must be a base64 encoded 32-byte key (`base64:...`). '
        'Generate one with `dartisan key:generate`.',
      );
    }
  }

  /// Generates a fresh `base64:<32 random bytes>` key.
  static String generateKey() => 'base64:${base64.encode(_randomBytes(32))}';

  /// JSON-encodes [value] then encrypts it.
  Future<String> encrypt(Object? value) => encryptString(jsonEncode(value));

  /// Decrypts a payload produced by [encrypt] and JSON-decodes it.
  Future<T> decrypt<T>(String payload) async {
    final decoded = jsonDecode(await decryptString(payload));
    if (decoded is! T) {
      throw DecryptException(
        'Decrypted value is ${decoded.runtimeType}, expected $T.',
      );
    }
    return decoded;
  }

  /// Encrypts [value] with the active key.
  Future<String> encryptString(String value) async {
    final plain = utf8.encode(value);
    final secret = cg.SecretKey(key);
    final Map<String, String> payload;
    switch (cipher) {
      case EncryptionCipher.aes256gcm:
        final iv = _randomBytes(12);
        final box = await cg.AesGcm.with256bits().encrypt(
          plain,
          secretKey: secret,
          nonce: iv,
        );
        payload = <String, String>{
          'iv': base64.encode(iv),
          'value': base64.encode(box.cipherText),
          'mac': '',
          'tag': base64.encode(box.mac.bytes),
        };
      case EncryptionCipher.aes256cbc:
        final iv = _randomBytes(16);
        final box = await cg.AesCbc.with256bits(
          macAlgorithm: cg.MacAlgorithm.empty,
        ).encrypt(plain, secretKey: secret, nonce: iv);
        final ivB64 = base64.encode(iv);
        final valueB64 = base64.encode(box.cipherText);
        payload = <String, String>{
          'iv': ivB64,
          'value': valueB64,
          'mac': _hmac(key, '$ivB64$valueB64'),
          'tag': '',
        };
    }
    return base64.encode(utf8.encode(jsonEncode(payload)));
  }

  /// Decrypts [payload], trying the active key first and then every
  /// previous key. Tampering, truncation or an unknown key throw
  /// [DecryptException].
  Future<String> decryptString(String payload) async {
    final parsed = _parsePayload(payload);
    for (final candidate in _keys) {
      final result = await _tryDecrypt(parsed, candidate);
      if (result != null) {
        return result;
      }
    }
    throw const DecryptException(
      'The payload is invalid or the MAC/tag is invalid.',
    );
  }

  Future<String?> _tryDecrypt(
    Map<String, Object?> payload,
    List<int> candidate,
  ) async {
    final Uint8List iv;
    final Uint8List value;
    try {
      iv = base64.decode(payload['iv']! as String);
      value = base64.decode(payload['value']! as String);
    } on FormatException {
      throw const DecryptException('The payload is invalid.');
    }
    final tag = payload['tag'] as String? ?? '';
    final mac = payload['mac'] as String? ?? '';
    final secret = cg.SecretKey(candidate);
    try {
      if (tag.isNotEmpty) {
        if (iv.length != 12) {
          return null;
        }
        final plain = await cg.AesGcm.with256bits().decrypt(
          cg.SecretBox(value, nonce: iv, mac: cg.Mac(base64.decode(tag))),
          secretKey: secret,
        );
        return utf8.decode(plain);
      }
      if (iv.length != 16) {
        return null;
      }
      final expected = _hmac(candidate, '${payload['iv']}${payload['value']}');
      if (!constantTimeEquals(expected, mac)) {
        return null;
      }
      final plain =
          await cg.AesCbc.with256bits(
            macAlgorithm: cg.MacAlgorithm.empty,
          ).decrypt(
            cg.SecretBox(value, nonce: iv, mac: cg.Mac.empty),
            secretKey: secret,
          );
      return utf8.decode(plain);
    } on cg.SecretBoxAuthenticationError {
      return null;
    } on cg.SecretBoxPaddingError {
      return null;
    } on FormatException {
      return null;
    }
  }

  static Map<String, Object?> _parsePayload(String payload) {
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(base64.decode(payload)));
    } on FormatException {
      throw const DecryptException('The payload is invalid.');
    }
    if (decoded is! Map<String, Object?> ||
        decoded['iv'] is! String ||
        decoded['value'] is! String) {
      throw const DecryptException('The payload is invalid.');
    }
    return decoded;
  }

  static String _hmac(List<int> key, String data) =>
      crypto.Hmac(crypto.sha256, key).convert(utf8.encode(data)).toString();

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }
}
