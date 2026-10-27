import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// End-to-end encryption of Pusher's `private-encrypted-` channels, as
/// `pusher-php-server` (and so Laravel) does it: NaCl's `secretbox`
/// (XSalsa20 and Poly1305, libsodium's `crypto_secretbox_easy`) with a key
/// per channel, `sha256(channel + master key)`.
///
/// The server only relays such events; the browser decrypts them with the
/// `shared_secret` that `/broadcasting/auth` hands it.
abstract final class PusherEncryption {
  static final Random _random = Random.secure();

  /// The channel's key: what `/broadcasting/auth` returns, base64-encoded,
  /// as `shared_secret`.
  static Uint8List sharedSecret(String channel, List<int> masterKey) =>
      Uint8List.fromList(
        sha256.convert([...utf8.encode(channel), ...masterKey]).bytes,
      );

  /// [data] encrypted for [channel]: `{"nonce": ..., "ciphertext": ...}`,
  /// base64, as Pusher clients expect it.
  static String encrypt(
    String channel,
    String data,
    List<int> masterKey, {
    Uint8List? nonce,
  }) {
    final n =
        nonce ??
        Uint8List.fromList(List.generate(24, (_) => _random.nextInt(256)));
    final box = Secretbox.seal(
      utf8.encode(data),
      n,
      sharedSecret(channel, masterKey),
    );
    return jsonEncode({
      'nonce': base64.encode(n),
      'ciphertext': base64.encode(box),
    });
  }
}

/// NaCl's `crypto_secretbox` (XSalsa20-Poly1305), in libsodium's
/// combined format: the 16-byte tag, then the ciphertext.
abstract final class Secretbox {
  /// Encrypts [message] with a 32-byte [key] and a 24-byte [nonce].
  static Uint8List seal(List<int> message, List<int> nonce, List<int> key) {
    if (key.length != 32 || nonce.length != 24) {
      throw ArgumentError('secretbox needs a 32-byte key and a 24-byte nonce.');
    }
    final stream = _xsalsa20(key, nonce, 32 + message.length);
    final ciphertext = Uint8List(message.length);
    for (var i = 0; i < message.length; i++) {
      ciphertext[i] = message[i] ^ stream[32 + i];
    }
    final tag = poly1305(ciphertext, stream.sublist(0, 32));
    return Uint8List.fromList([...tag, ...ciphertext]);
  }

  /// Decrypts a [seal]ed box; null when the tag does not match.
  static Uint8List? open(List<int> box, List<int> nonce, List<int> key) {
    if (box.length < 16 || key.length != 32 || nonce.length != 24) {
      return null;
    }
    final ciphertext = box.sublist(16);
    final stream = _xsalsa20(key, nonce, 32 + ciphertext.length);
    final tag = poly1305(ciphertext, stream.sublist(0, 32));
    var difference = 0;
    for (var i = 0; i < 16; i++) {
      difference |= tag[i] ^ box[i];
    }
    if (difference != 0) {
      return null;
    }
    return Uint8List.fromList([
      for (var i = 0; i < ciphertext.length; i++)
        ciphertext[i] ^ stream[32 + i],
    ]);
  }

  /// Poly1305 (RFC 8439 §2.5) of [message] with a one-time 32-byte [key].
  static Uint8List poly1305(List<int> message, List<int> key) {
    BigInt le(List<int> bytes) {
      var n = BigInt.zero;
      for (var i = bytes.length - 1; i >= 0; i--) {
        n = (n << 8) | BigInt.from(bytes[i]);
      }
      return n;
    }

    final r =
        le(key.sublist(0, 16)) &
        BigInt.parse('0ffffffc0ffffffc0ffffffc0fffffff', radix: 16);
    final s = le(key.sublist(16, 32));
    final p = (BigInt.one << 130) - BigInt.from(5);
    var accumulator = BigInt.zero;
    for (var i = 0; i < message.length; i += 16) {
      final block = message.sublist(i, min(i + 16, message.length));
      final n = le(block) | (BigInt.one << (8 * block.length));
      accumulator = ((accumulator + n) * r) % p;
    }
    var tag = (accumulator + s) & ((BigInt.one << 128) - BigInt.one);
    final out = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      out[i] = (tag & BigInt.from(0xff)).toInt();
      tag >>= 8;
    }
    return out;
  }

  /// [length] bytes of XSalsa20 keystream: HSalsa20 of the key and the
  /// first 16 nonce bytes gives a subkey, then Salsa20 with the last 8.
  static Uint8List _xsalsa20(List<int> key, List<int> nonce, int length) {
    final subkey = _hsalsa20(_words(key, 8), _words(nonce.sublist(0, 16), 4));
    final tail = _words(nonce.sublist(16, 24), 2);
    final out = Uint8List(length);
    final state = Uint32List(16);
    final block = Uint32List(16);
    for (
      var counter = 0, offset = 0;
      offset < length;
      counter++, offset += 64
    ) {
      _salsaState(state, subkey, tail[0], tail[1], counter);
      _salsa20(state, block);
      for (var i = 0; i < 64 && offset + i < length; i++) {
        out[offset + i] = (block[i >> 2] >> ((i & 3) * 8)) & 0xff;
      }
    }
    return out;
  }

  static const List<int> _sigma = [
    0x61707865,
    0x3320646e,
    0x79622d32,
    0x6b206574,
  ];

  static void _salsaState(
    Uint32List state,
    Uint32List key,
    int nonce0,
    int nonce1,
    int counter,
  ) {
    state
      ..[0] = _sigma[0]
      ..[1] = key[0]
      ..[2] = key[1]
      ..[3] = key[2]
      ..[4] = key[3]
      ..[5] = _sigma[1]
      ..[6] = nonce0
      ..[7] = nonce1
      ..[8] = counter & 0xffffffff
      ..[9] = (counter >> 32) & 0xffffffff
      ..[10] = _sigma[2]
      ..[11] = key[4]
      ..[12] = key[5]
      ..[13] = key[6]
      ..[14] = key[7]
      ..[15] = _sigma[3];
  }

  /// Salsa20/20 of [input] into [output] (the rounds, then the addition).
  static void _salsa20(Uint32List input, Uint32List output) {
    final x = Uint32List.fromList(input);
    _rounds(x);
    for (var i = 0; i < 16; i++) {
      output[i] = x[i] + input[i];
    }
  }

  /// HSalsa20: the rounds without the final addition, words 0, 5, 10, 15,
  /// 6, 7, 8, 9 of the result.
  static Uint32List _hsalsa20(Uint32List key, Uint32List nonce) {
    final x = Uint32List(16)
      ..[0] = _sigma[0]
      ..[1] = key[0]
      ..[2] = key[1]
      ..[3] = key[2]
      ..[4] = key[3]
      ..[5] = _sigma[1]
      ..[6] = nonce[0]
      ..[7] = nonce[1]
      ..[8] = nonce[2]
      ..[9] = nonce[3]
      ..[10] = _sigma[2]
      ..[11] = key[4]
      ..[12] = key[5]
      ..[13] = key[6]
      ..[14] = key[7]
      ..[15] = _sigma[3];
    _rounds(x);
    return Uint32List.fromList([
      x[0],
      x[5],
      x[10],
      x[15],
      x[6],
      x[7],
      x[8],
      x[9],
    ]);
  }

  static int _rotl(int v, int c) =>
      ((v << c) | ((v & 0xffffffff) >> (32 - c))) & 0xffffffff;

  /// Salsa20's 20 rounds (10 double rounds) in place.
  static void _rounds(Uint32List x) {
    void quarter(int a, int b, int c, int d) {
      x[b] ^= _rotl(x[a] + x[d], 7);
      x[c] ^= _rotl(x[b] + x[a], 9);
      x[d] ^= _rotl(x[c] + x[b], 13);
      x[a] ^= _rotl(x[d] + x[c], 18);
    }

    for (var i = 0; i < 10; i++) {
      // Columns.
      quarter(0, 4, 8, 12);
      quarter(5, 9, 13, 1);
      quarter(10, 14, 2, 6);
      quarter(15, 3, 7, 11);
      // Rows.
      quarter(0, 1, 2, 3);
      quarter(5, 6, 7, 4);
      quarter(10, 11, 8, 9);
      quarter(15, 12, 13, 14);
    }
  }

  /// Little-endian 32-bit words of [bytes].
  static Uint32List _words(List<int> bytes, int count) {
    final out = Uint32List(count);
    for (var i = 0; i < count; i++) {
      out[i] =
          bytes[i * 4] |
          (bytes[i * 4 + 1] << 8) |
          (bytes[i * 4 + 2] << 16) |
          (bytes[i * 4 + 3] << 24);
    }
    return out;
  }
}
