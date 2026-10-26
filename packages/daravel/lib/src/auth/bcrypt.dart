import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'blowfish_tables.dart';
import 'native_crypt.dart';

/// bcrypt (Provos and Mazieres, 1999), the `$2y$` hashes of PHP's
/// `password_hash` and Laravel's `Hash::make`.
///
/// On Linux it runs the system's C bcrypt ([NativeCrypt], the one PHP
/// uses); elsewhere a Dart implementation written for AOT speed: separate
/// [Uint32List] S-boxes, Blowfish's rounds written out, no bounds checks in
/// the hot loops. Both give the same hashes. It reads `$2a$`, `$2b$` and
/// `$2y$` hashes (the same algorithm for passwords under 256 bytes) and
/// writes `$2y$`, as PHP does.
abstract final class Bcrypt {
  static final Random _random = Random.secure();

  /// A new hash of [password] with 2^[cost] rounds (4 to 31).
  static String hash(String password, {int cost = 12, String prefix = r'$2y'}) {
    final salt = Uint8List(16);
    for (var i = 0; i < 16; i++) {
      salt[i] = _random.nextInt(256);
    }
    return hashWithSalt(password, salt, cost: cost, prefix: prefix);
  }

  /// The hash of [password] with [salt] (16 bytes): deterministic, for
  /// tests and for [verify].
  ///
  /// [native] false forces the Dart implementation (tests compare the two).
  static String hashWithSalt(
    String password,
    Uint8List salt, {
    int cost = 12,
    String prefix = r'$2y',
    bool native = true,
  }) {
    if (cost < 4 || cost > 31) {
      throw ArgumentError.value(cost, 'cost', 'must be between 4 and 31');
    }
    if (salt.length != 16) {
      throw ArgumentError.value(salt.length, 'salt', 'must be 16 bytes');
    }
    final setting =
        '$prefix\$${cost.toString().padLeft(2, '0')}\$${_encode(salt, 16)}';
    // C strings end at a NUL, so such passwords take the Dart path.
    if (native && NativeCrypt.available && !password.contains('\u0000')) {
      final hashed = NativeCrypt.crypt(password, setting);
      if (hashed != null) {
        return hashed;
      }
    }
    return '$setting${_encode(_crypt(_key(password), salt, cost), 23)}';
  }

  /// Whether [password] matches [hashed] (`$2a$`, `$2b$` or `$2y$`), in
  /// time that does not depend on where the two differ. A malformed hash
  /// never matches.
  static bool verify(String password, String hashed, {bool native = true}) {
    final match = _format.firstMatch(hashed);
    if (match == null) {
      return false;
    }
    final salt = _decode(match[3]!, 16);
    if (salt == null) {
      return false;
    }
    final expected = hashWithSalt(
      password,
      salt,
      cost: int.parse(match[2]!),
      prefix: match[1]!,
      native: native,
    );
    var difference = expected.length ^ hashed.length;
    for (var i = 0; i < expected.length && i < hashed.length; i++) {
      difference |= expected.codeUnitAt(i) ^ hashed.codeUnitAt(i);
    }
    return difference == 0;
  }

  static final RegExp _format = RegExp(
    r'^(\$2[aby])\$(0[4-9]|[12][0-9]|3[01])\$([./A-Za-z0-9]{22})[./A-Za-z0-9]{31}$',
  );

  /// The key: the password's UTF-8 bytes with a terminating zero, at most
  /// 72 bytes.
  static Uint8List _key(String password) {
    final bytes = utf8.encode(password);
    final length = min(bytes.length + 1, 72);
    final key = Uint8List(length);
    key.setRange(0, min(bytes.length, length), bytes);
    return key;
  }

  static Uint8List _crypt(Uint8List key, Uint8List salt, int cost) {
    final state = _Blowfish();
    final keyWords = _words(key);
    final saltWords = _words(salt);
    state.expand(keyWords, saltWords);
    final rounds = 1 << cost;
    for (var i = 0; i < rounds; i++) {
      state
        ..expand(keyWords, null)
        ..expand(saltWords, null);
    }
    final text = Uint32List.fromList(bcryptMagic);
    for (var i = 0; i < 64; i++) {
      for (var j = 0; j < 6; j += 2) {
        state.encrypt(text, j);
      }
    }
    final out = Uint8List(24);
    for (var i = 0; i < 6; i++) {
      out[i * 4] = text[i] >> 24;
      out[i * 4 + 1] = text[i] >> 16;
      out[i * 4 + 2] = text[i] >> 8;
      out[i * 4 + 3] = text[i];
    }
    return Uint8List.sublistView(out, 0, 23);
  }

  /// [bytes] read cyclically as big-endian words: the 18 + 1024 + ... the
  /// key schedule asks for, precomputed once (a key repeats every
  /// [bytes].length words).
  static Uint32List _words(Uint8List bytes) {
    final words = Uint32List(bytes.length);
    var offset = 0;
    for (var i = 0; i < words.length; i++) {
      var word = 0;
      for (var b = 0; b < 4; b++) {
        word = (word << 8) | bytes[offset];
        offset = offset + 1 == bytes.length ? 0 : offset + 1;
      }
      words[i] = word;
    }
    return words;
  }

  static const String _alphabet =
      './ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  /// bcrypt's base64: its own alphabet, no padding.
  static String _encode(Uint8List data, int length) {
    final out = StringBuffer();
    var i = 0;
    while (i < length) {
      var c1 = data[i++];
      out.write(_alphabet[c1 >> 2]);
      c1 = (c1 & 0x03) << 4;
      if (i >= length) {
        out.write(_alphabet[c1]);
        break;
      }
      var c2 = data[i++];
      c1 |= c2 >> 4;
      out.write(_alphabet[c1]);
      c1 = (c2 & 0x0f) << 2;
      if (i >= length) {
        out.write(_alphabet[c1]);
        break;
      }
      c2 = data[i++];
      c1 |= c2 >> 6;
      out
        ..write(_alphabet[c1])
        ..write(_alphabet[c2 & 0x3f]);
    }
    return out.toString();
  }

  static Uint8List? _decode(String text, int length) {
    final out = Uint8List(length);
    var o = 0;
    var i = 0;
    int value(int index) => _alphabet.indexOf(text[index]);
    while (o < length && i < text.length - 1) {
      final c1 = value(i++);
      final c2 = value(i++);
      if (c1 < 0 || c2 < 0) {
        return null;
      }
      out[o++] = (c1 << 2) | ((c2 & 0x30) >> 4);
      if (o >= length || i >= text.length) {
        break;
      }
      final c3 = value(i++);
      if (c3 < 0) {
        return null;
      }
      out[o++] = ((c2 & 0x0f) << 4) | ((c3 & 0x3c) >> 2);
      if (o >= length || i >= text.length) {
        break;
      }
      final c4 = value(i++);
      if (c4 < 0) {
        return null;
      }
      out[o++] = ((c3 & 0x03) << 6) | c4;
    }
    return o == length ? out : null;
  }
}

/// Blowfish's state: the P-array and four S-boxes.
///
/// The rounds are written out (`tool/bcrypt/generate.dart` style) and the
/// hot functions skip bounds checks: every index is a byte (`& 0xff`) into
/// a 256-entry S-box, a constant below 18 into the P-array, or a loop index
/// below the table's length. `l` and `r` may carry bits above 32 (the
/// additions are not masked): only their low 32 bits select table entries,
/// and the tables store 32 bits.
final class _Blowfish {
  final Uint32List p = Uint32List.fromList(blowfishP);
  final Uint32List s0 = Uint32List.fromList(blowfishS0);
  final Uint32List s1 = Uint32List.fromList(blowfishS1);
  final Uint32List s2 = Uint32List.fromList(blowfishS2);
  final Uint32List s3 = Uint32List.fromList(blowfishS3);

  @pragma('vm:unsafe:no-bounds-checks')
  void encrypt(Uint32List block, int offset) {
    final p = this.p;
    final s0 = this.s0;
    final s1 = this.s1;
    final s2 = this.s2;
    final s3 = this.s3;
    final p0 = p[0];
    var l = block[offset];
    var r = block[offset + 1];
    l ^= p0;
    r ^=
        (((s0[(l >> 24) & 0xff] + s1[(l >> 16) & 0xff]) ^ s2[(l >> 8) & 0xff]) +
            s3[l & 0xff]) ^
        p[1];
    l ^=
        (((s0[(r >> 24) & 0xff] + s1[(r >> 16) & 0xff]) ^ s2[(r >> 8) & 0xff]) +
            s3[r & 0xff]) ^
        p[2];
    r ^=
        (((s0[(l >> 24) & 0xff] + s1[(l >> 16) & 0xff]) ^ s2[(l >> 8) & 0xff]) +
            s3[l & 0xff]) ^
        p[3];
    l ^=
        (((s0[(r >> 24) & 0xff] + s1[(r >> 16) & 0xff]) ^ s2[(r >> 8) & 0xff]) +
            s3[r & 0xff]) ^
        p[4];
    r ^=
        (((s0[(l >> 24) & 0xff] + s1[(l >> 16) & 0xff]) ^ s2[(l >> 8) & 0xff]) +
            s3[l & 0xff]) ^
        p[5];
    l ^=
        (((s0[(r >> 24) & 0xff] + s1[(r >> 16) & 0xff]) ^ s2[(r >> 8) & 0xff]) +
            s3[r & 0xff]) ^
        p[6];
    r ^=
        (((s0[(l >> 24) & 0xff] + s1[(l >> 16) & 0xff]) ^ s2[(l >> 8) & 0xff]) +
            s3[l & 0xff]) ^
        p[7];
    l ^=
        (((s0[(r >> 24) & 0xff] + s1[(r >> 16) & 0xff]) ^ s2[(r >> 8) & 0xff]) +
            s3[r & 0xff]) ^
        p[8];
    r ^=
        (((s0[(l >> 24) & 0xff] + s1[(l >> 16) & 0xff]) ^ s2[(l >> 8) & 0xff]) +
            s3[l & 0xff]) ^
        p[9];
    l ^=
        (((s0[(r >> 24) & 0xff] + s1[(r >> 16) & 0xff]) ^ s2[(r >> 8) & 0xff]) +
            s3[r & 0xff]) ^
        p[10];
    r ^=
        (((s0[(l >> 24) & 0xff] + s1[(l >> 16) & 0xff]) ^ s2[(l >> 8) & 0xff]) +
            s3[l & 0xff]) ^
        p[11];
    l ^=
        (((s0[(r >> 24) & 0xff] + s1[(r >> 16) & 0xff]) ^ s2[(r >> 8) & 0xff]) +
            s3[r & 0xff]) ^
        p[12];
    r ^=
        (((s0[(l >> 24) & 0xff] + s1[(l >> 16) & 0xff]) ^ s2[(l >> 8) & 0xff]) +
            s3[l & 0xff]) ^
        p[13];
    l ^=
        (((s0[(r >> 24) & 0xff] + s1[(r >> 16) & 0xff]) ^ s2[(r >> 8) & 0xff]) +
            s3[r & 0xff]) ^
        p[14];
    r ^=
        (((s0[(l >> 24) & 0xff] + s1[(l >> 16) & 0xff]) ^ s2[(l >> 8) & 0xff]) +
            s3[l & 0xff]) ^
        p[15];
    l ^=
        (((s0[(r >> 24) & 0xff] + s1[(r >> 16) & 0xff]) ^ s2[(r >> 8) & 0xff]) +
            s3[r & 0xff]) ^
        p[16];
    final swap = r ^ p[17];
    r = l;
    l = swap;
    block[offset] = l;
    block[offset + 1] = r;
  }

  /// bcrypt's key schedule: [key] into the P-array, then every P and S
  /// entry from the running encryption, mixed with [salt] when given
  /// (EksBlowfishSetup's ExpandKey; `salt == null` is the zero salt).
  @pragma('vm:unsafe:no-bounds-checks')
  void expand(Uint32List key, Uint32List? salt) {
    final p = this.p;
    final s0 = this.s0;
    final s1 = this.s1;
    final s2 = this.s2;
    final s3 = this.s3;
    var k = 0;
    for (var i = 0; i < 18; i++) {
      p[i] ^= key[k];
      k = k + 1 == key.length ? 0 : k + 1;
    }
    var l = 0;
    var r = 0;
    var t = 0;
    final saltLength = salt?.length ?? 0;
    var table = p;
    var length = 18;
    for (var which = 0; which < 5; which++) {
      for (var i = 0; i < length; i += 2) {
        if (salt != null) {
          l ^= salt[t];
          t = t + 1 == saltLength ? 0 : t + 1;
          r ^= salt[t];
          t = t + 1 == saltLength ? 0 : t + 1;
        }
        // p[0] changes while the P-array is being filled.
        final p0 = p[0];
        l ^= p0;
        r ^=
            (((s0[(l >> 24) & 0xff] + s1[(l >> 16) & 0xff]) ^
                    s2[(l >> 8) & 0xff]) +
                s3[l & 0xff]) ^
            p[1];
        l ^=
            (((s0[(r >> 24) & 0xff] + s1[(r >> 16) & 0xff]) ^
                    s2[(r >> 8) & 0xff]) +
                s3[r & 0xff]) ^
            p[2];
        r ^=
            (((s0[(l >> 24) & 0xff] + s1[(l >> 16) & 0xff]) ^
                    s2[(l >> 8) & 0xff]) +
                s3[l & 0xff]) ^
            p[3];
        l ^=
            (((s0[(r >> 24) & 0xff] + s1[(r >> 16) & 0xff]) ^
                    s2[(r >> 8) & 0xff]) +
                s3[r & 0xff]) ^
            p[4];
        r ^=
            (((s0[(l >> 24) & 0xff] + s1[(l >> 16) & 0xff]) ^
                    s2[(l >> 8) & 0xff]) +
                s3[l & 0xff]) ^
            p[5];
        l ^=
            (((s0[(r >> 24) & 0xff] + s1[(r >> 16) & 0xff]) ^
                    s2[(r >> 8) & 0xff]) +
                s3[r & 0xff]) ^
            p[6];
        r ^=
            (((s0[(l >> 24) & 0xff] + s1[(l >> 16) & 0xff]) ^
                    s2[(l >> 8) & 0xff]) +
                s3[l & 0xff]) ^
            p[7];
        l ^=
            (((s0[(r >> 24) & 0xff] + s1[(r >> 16) & 0xff]) ^
                    s2[(r >> 8) & 0xff]) +
                s3[r & 0xff]) ^
            p[8];
        r ^=
            (((s0[(l >> 24) & 0xff] + s1[(l >> 16) & 0xff]) ^
                    s2[(l >> 8) & 0xff]) +
                s3[l & 0xff]) ^
            p[9];
        l ^=
            (((s0[(r >> 24) & 0xff] + s1[(r >> 16) & 0xff]) ^
                    s2[(r >> 8) & 0xff]) +
                s3[r & 0xff]) ^
            p[10];
        r ^=
            (((s0[(l >> 24) & 0xff] + s1[(l >> 16) & 0xff]) ^
                    s2[(l >> 8) & 0xff]) +
                s3[l & 0xff]) ^
            p[11];
        l ^=
            (((s0[(r >> 24) & 0xff] + s1[(r >> 16) & 0xff]) ^
                    s2[(r >> 8) & 0xff]) +
                s3[r & 0xff]) ^
            p[12];
        r ^=
            (((s0[(l >> 24) & 0xff] + s1[(l >> 16) & 0xff]) ^
                    s2[(l >> 8) & 0xff]) +
                s3[l & 0xff]) ^
            p[13];
        l ^=
            (((s0[(r >> 24) & 0xff] + s1[(r >> 16) & 0xff]) ^
                    s2[(r >> 8) & 0xff]) +
                s3[r & 0xff]) ^
            p[14];
        r ^=
            (((s0[(l >> 24) & 0xff] + s1[(l >> 16) & 0xff]) ^
                    s2[(l >> 8) & 0xff]) +
                s3[l & 0xff]) ^
            p[15];
        l ^=
            (((s0[(r >> 24) & 0xff] + s1[(r >> 16) & 0xff]) ^
                    s2[(r >> 8) & 0xff]) +
                s3[r & 0xff]) ^
            p[16];
        final swap = r ^ p[17];
        r = l;
        l = swap;
        table[i] = l;
        table[i + 1] = r;
      }
      table = switch (which) {
        0 => s0,
        1 => s1,
        2 => s2,
        _ => s3,
      };
      length = 256;
    }
  }
}
