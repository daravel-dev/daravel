// Ported from xxHash, Extremely Fast Hash algorithm (xxhash.h v0.8.2):
// Copyright (C) 2012-2021 Yann Collet
//
// BSD 2-Clause License (https://www.opensource.org/licenses/bsd-license.php)
//
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are
// met:
//
//    * Redistributions of source code must retain the above copyright
//      notice, this list of conditions and the following disclaimer.
//    * Redistributions in binary form must reproduce the above
//      copyright notice, this list of conditions and the following disclaimer
//      in the documentation and/or other materials provided with the
//      distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
// A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
// OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
// SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
// LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
// DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
// THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
// (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
// OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

import 'dart:convert';
import 'dart:typed_data';

/// XXH3-128 with the default secret and seed 0: PHP's `hash('xxh128', …)`,
/// which Laravel uses for the queue lock key of a job class that defines
/// `displayName()` (`UniqueLock::getKey`, `WithoutOverlapping::getLockKey`,
/// `DebounceLock::getKey`; ADR-041).
///
/// Ported from the reference implementation, `xxhash.h` v0.8.2
/// (github.com/Cyan4973/xxHash, BSD 2-Clause): `XXH3_128bits` and the
/// scalar paths it takes for each input length. It relies on Dart's 64-bit
/// integers wrapping on overflow (the native VM and AOT, not the web).
abstract final class Xxh128 {
  /// The hash of [input]'s UTF-8 bytes as 32 lowercase hex digits, high
  /// half first (`XXH128_canonicalFromHash`, PHP's output).
  static String hex(String input) => hexOf(utf8.encode(input));

  /// The hash of [bytes] as 32 lowercase hex digits.
  static String hexOf(List<int> bytes) {
    final (high, low) = of(bytes);
    return '${_hex64(high)}${_hex64(low)}';
  }

  /// The hash of [bytes] as its (high, low) 64-bit halves.
  static (int, int) of(List<int> bytes) {
    final input = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final len = input.length;
    if (len <= 16) {
      return _len0to16(input, len);
    }
    if (len <= 128) {
      return _len17to128(input, len);
    }
    if (len <= 240) {
      return _len129to240(input, len);
    }
    return _hashLong(input, len);
  }

  // -- Constants (xxhash.h) ------------------------------------------------

  static const int _prime32_1 = 0x9E3779B1;
  static const int _prime32_2 = 0x85EBCA77;
  static const int _prime32_3 = 0xC2B2AE3D;
  static const int _prime64_1 = 0x9E3779B185EBCA87;
  static const int _prime64_2 = 0xC2B2AE3D27D4EB4F;
  static const int _prime64_3 = 0x165667B19E3779F9;
  static const int _prime64_4 = 0x85EBCA77C2B2AE63;
  static const int _prime64_5 = 0x27D4EB2F165667C5;
  static const int _primeMx1 = 0x165667919E3779F9;
  static const int _primeMx2 = 0x9FB21C651E98DF25;

  static const int _secretSizeMin = 136;
  static const int _midsizeStartOffset = 3;
  static const int _midsizeLastOffset = 17;
  static const int _stripeLen = 64;
  static const int _secretConsumeRate = 8;
  static const int _accNb = 8;
  static const int _secretLastAccStart = 7;
  static const int _secretMergeAccsStart = 11;
  static const int _mask32 = 0xFFFFFFFF;

  /// `XXH3_kSecret` (192 bytes).
  static final Uint8List _secret = Uint8List.fromList(const [
    0xb8, 0xfe, 0x6c, 0x39, 0x23, 0xa4, 0x4b, 0xbe, 0x7c, 0x01, 0x81, 0x2c, //
    0xf7, 0x21, 0xad, 0x1c, 0xde, 0xd4, 0x6d, 0xe9, 0x83, 0x90, 0x97, 0xdb,
    0x72, 0x40, 0xa4, 0xa4, 0xb7, 0xb3, 0x67, 0x1f, 0xcb, 0x79, 0xe6, 0x4e,
    0xcc, 0xc0, 0xe5, 0x78, 0x82, 0x5a, 0xd0, 0x7d, 0xcc, 0xff, 0x72, 0x21,
    0xb8, 0x08, 0x46, 0x74, 0xf7, 0x43, 0x24, 0x8e, 0xe0, 0x35, 0x90, 0xe6,
    0x81, 0x3a, 0x26, 0x4c, 0x3c, 0x28, 0x52, 0xbb, 0x91, 0xc3, 0x00, 0xcb,
    0x88, 0xd0, 0x65, 0x8b, 0x1b, 0x53, 0x2e, 0xa3, 0x71, 0x64, 0x48, 0x97,
    0xa2, 0x0d, 0xf9, 0x4e, 0x38, 0x19, 0xef, 0x46, 0xa9, 0xde, 0xac, 0xd8,
    0xa8, 0xfa, 0x76, 0x3f, 0xe3, 0x9c, 0x34, 0x3f, 0xf9, 0xdc, 0xbb, 0xc7,
    0xc7, 0x0b, 0x4f, 0x1d, 0x8a, 0x51, 0xe0, 0x4b, 0xcd, 0xb4, 0x59, 0x31,
    0xc8, 0x9f, 0x7e, 0xc9, 0xd9, 0x78, 0x73, 0x64, 0xea, 0xc5, 0xac, 0x83,
    0x34, 0xd3, 0xeb, 0xc3, 0xc5, 0x81, 0xa0, 0xff, 0xfa, 0x13, 0x63, 0xeb,
    0x17, 0x0d, 0xdd, 0x51, 0xb7, 0xf0, 0xda, 0x49, 0xd3, 0x16, 0x55, 0x26,
    0x29, 0xd4, 0x68, 0x9e, 0x2b, 0x16, 0xbe, 0x58, 0x7d, 0x47, 0xa1, 0xfc,
    0x8f, 0xf8, 0xb8, 0xd1, 0x7a, 0xd0, 0x31, 0xce, 0x45, 0xcb, 0x3a, 0x8f,
    0x95, 0x16, 0x04, 0x28, 0xaf, 0xd7, 0xfb, 0xca, 0xbb, 0x4b, 0x40, 0x7e,
  ]);

  // -- Helpers -------------------------------------------------------------

  static int _read64(Uint8List b, int i) =>
      b[i] |
      (b[i + 1] << 8) |
      (b[i + 2] << 16) |
      (b[i + 3] << 24) |
      (b[i + 4] << 32) |
      (b[i + 5] << 40) |
      (b[i + 6] << 48) |
      (b[i + 7] << 56);

  static int _read32(Uint8List b, int i) =>
      b[i] | (b[i + 1] << 8) | (b[i + 2] << 16) | (b[i + 3] << 24);

  static int _swap32(int x) =>
      ((x & 0xFF) << 24) |
      ((x & 0xFF00) << 8) |
      ((x >>> 8) & 0xFF00) |
      ((x >>> 24) & 0xFF);

  static int _swap64(int x) =>
      (_swap32(x & _mask32) << 32) | _swap32((x >>> 32) & _mask32);

  static int _rotl32(int x, int r) =>
      ((x << r) | ((x & _mask32) >>> (32 - r))) & _mask32;

  static int _xorshift64(int v, int shift) => v ^ (v >>> shift);

  /// `XXH_mult64to128`: the 128-bit product of two 64-bit words as
  /// (high, low).
  static (int, int) _mult64to128(int lhs, int rhs) {
    final loLo = (lhs & _mask32) * (rhs & _mask32);
    final hiLo = (lhs >>> 32) * (rhs & _mask32);
    final loHi = (lhs & _mask32) * (rhs >>> 32);
    final hiHi = (lhs >>> 32) * (rhs >>> 32);
    final cross = (loLo >>> 32) + (hiLo & _mask32) + loHi;
    final upper = (hiLo >>> 32) + (cross >>> 32) + hiHi;
    final lower = (cross << 32) | (loLo & _mask32);
    return (upper, lower);
  }

  static int _mul128Fold64(int lhs, int rhs) {
    final (high, low) = _mult64to128(lhs, rhs);
    return high ^ low;
  }

  static int _xxh64Avalanche(int h) {
    var hash = h;
    hash ^= hash >>> 33;
    hash *= _prime64_2;
    hash ^= hash >>> 29;
    hash *= _prime64_3;
    hash ^= hash >>> 32;
    return hash;
  }

  static int _avalanche(int h) {
    var h64 = _xorshift64(h, 37);
    h64 *= _primeMx1;
    return _xorshift64(h64, 32);
  }

  static int _mix16B(Uint8List input, int i, int s) => _mul128Fold64(
    _read64(input, i) ^ _read64(_secret, s),
    _read64(input, i + 8) ^ _read64(_secret, s + 8),
  );

  // -- Lengths 0 to 16 -----------------------------------------------------

  static (int, int) _len0to16(Uint8List input, int len) {
    if (len > 8) {
      return _len9to16(input, len);
    }
    if (len >= 4) {
      return _len4to8(input, len);
    }
    if (len > 0) {
      return _len1to3(input, len);
    }
    final bitflipl = _read64(_secret, 64) ^ _read64(_secret, 72);
    final bitfliph = _read64(_secret, 80) ^ _read64(_secret, 88);
    return (_xxh64Avalanche(bitfliph), _xxh64Avalanche(bitflipl));
  }

  static (int, int) _len1to3(Uint8List input, int len) {
    final c1 = input[0];
    final c2 = input[len >> 1];
    final c3 = input[len - 1];
    final combinedl = ((c1 << 16) | (c2 << 24) | c3 | (len << 8)) & _mask32;
    final combinedh = _rotl32(_swap32(combinedl), 13);
    final bitflipl = _read32(_secret, 0) ^ _read32(_secret, 4);
    final bitfliph = _read32(_secret, 8) ^ _read32(_secret, 12);
    final keyedLo = combinedl ^ bitflipl;
    final keyedHi = combinedh ^ bitfliph;
    return (_xxh64Avalanche(keyedHi), _xxh64Avalanche(keyedLo));
  }

  static (int, int) _len4to8(Uint8List input, int len) {
    final inputLo = _read32(input, 0);
    final inputHi = _read32(input, len - 4);
    final input64 = inputLo + (inputHi << 32);
    final bitflip = _read64(_secret, 16) ^ _read64(_secret, 24);
    final keyed = input64 ^ bitflip;
    var (high, low) = _mult64to128(keyed, _prime64_1 + (len << 2));
    high += low << 1;
    low ^= high >>> 3;
    low = _xorshift64(low, 35);
    low *= _primeMx2;
    low = _xorshift64(low, 28);
    high = _avalanche(high);
    return (high, low);
  }

  static (int, int) _len9to16(Uint8List input, int len) {
    final bitflipl = _read64(_secret, 32) ^ _read64(_secret, 40);
    final bitfliph = _read64(_secret, 48) ^ _read64(_secret, 56);
    final inputLo = _read64(input, 0);
    var inputHi = _read64(input, len - 8);
    var (mHigh, mLow) = _mult64to128(inputLo ^ inputHi ^ bitflipl, _prime64_1);
    mLow += (len - 1) << 54;
    inputHi ^= bitfliph;
    // The 64-bit branch of xxhash.h.
    mHigh += inputHi + (inputHi & _mask32) * (_prime32_2 - 1);
    mLow ^= _swap64(mHigh);
    var (high, low) = _mult64to128(mLow, _prime64_2);
    high += mHigh * _prime64_2;
    return (_avalanche(high), _avalanche(low));
  }

  // -- Lengths 17 to 240 ---------------------------------------------------

  /// `XXH128_mix32B` on (low, high).
  static (int, int) _mix32B(
    int accLow,
    int accHigh,
    Uint8List input,
    int i1,
    int i2,
    int s,
  ) {
    var low = accLow + _mix16B(input, i1, s);
    low ^= _read64(input, i2) + _read64(input, i2 + 8);
    var high = accHigh + _mix16B(input, i2, s + 16);
    high ^= _read64(input, i1) + _read64(input, i1 + 8);
    return (low, high);
  }

  static (int, int) _finishMid(int accLow, int accHigh, int len) {
    final low = _avalanche(accLow + accHigh);
    final high =
        0 -
        _avalanche(
          accLow * _prime64_1 + accHigh * _prime64_4 + len * _prime64_2,
        );
    return (high, low);
  }

  static (int, int) _len17to128(Uint8List input, int len) {
    var low = len * _prime64_1;
    var high = 0;
    if (len > 32) {
      if (len > 64) {
        if (len > 96) {
          (low, high) = _mix32B(low, high, input, 48, len - 64, 96);
        }
        (low, high) = _mix32B(low, high, input, 32, len - 48, 64);
      }
      (low, high) = _mix32B(low, high, input, 16, len - 32, 32);
    }
    (low, high) = _mix32B(low, high, input, 0, len - 16, 0);
    return _finishMid(low, high, len);
  }

  static (int, int) _len129to240(Uint8List input, int len) {
    var low = len * _prime64_1;
    var high = 0;
    for (var i = 32; i < 160; i += 32) {
      (low, high) = _mix32B(low, high, input, i - 32, i - 16, i - 32);
    }
    low = _avalanche(low);
    high = _avalanche(high);
    for (var i = 160; i <= len; i += 32) {
      (low, high) = _mix32B(
        low,
        high,
        input,
        i - 32,
        i - 16,
        _midsizeStartOffset + i - 160,
      );
    }
    // Seed 0: the last mix's seed (0 - seed) is 0 too.
    (low, high) = _mix32B(
      low,
      high,
      input,
      len - 16,
      len - 32,
      _secretSizeMin - _midsizeLastOffset - 16,
    );
    return _finishMid(low, high, len);
  }

  // -- Long inputs (> 240) -------------------------------------------------

  static void _accumulate512(List<int> acc, Uint8List input, int i, int s) {
    for (var lane = 0; lane < _accNb; lane++) {
      final dataVal = _read64(input, i + lane * 8);
      final dataKey = dataVal ^ _read64(_secret, s + lane * 8);
      acc[lane ^ 1] += dataVal;
      acc[lane] += (dataKey & _mask32) * (dataKey >>> 32);
    }
  }

  static void _scrambleAcc(List<int> acc, int s) {
    for (var lane = 0; lane < _accNb; lane++) {
      var acc64 = acc[lane];
      acc64 = _xorshift64(acc64, 47);
      acc64 ^= _read64(_secret, s + lane * 8);
      acc64 *= _prime32_1;
      acc[lane] = acc64;
    }
  }

  static int _mergeAccs(List<int> acc, int s, int start) {
    var result = start;
    for (var i = 0; i < 4; i++) {
      result += _mul128Fold64(
        acc[2 * i] ^ _read64(_secret, s + 16 * i),
        acc[2 * i + 1] ^ _read64(_secret, s + 16 * i + 8),
      );
    }
    return _avalanche(result);
  }

  static (int, int) _hashLong(Uint8List input, int len) {
    final acc = <int>[
      _prime32_3,
      _prime64_1,
      _prime64_2,
      _prime64_3,
      _prime64_4,
      _prime32_2,
      _prime64_5,
      _prime32_1,
    ];
    final secretSize = _secret.length;
    final stripesPerBlock = (secretSize - _stripeLen) ~/ _secretConsumeRate;
    final blockLen = _stripeLen * stripesPerBlock;
    final blocks = (len - 1) ~/ blockLen;
    for (var n = 0; n < blocks; n++) {
      for (var stripe = 0; stripe < stripesPerBlock; stripe++) {
        _accumulate512(
          acc,
          input,
          n * blockLen + stripe * _stripeLen,
          stripe * _secretConsumeRate,
        );
      }
      _scrambleAcc(acc, secretSize - _stripeLen);
    }
    final stripes = ((len - 1) - blockLen * blocks) ~/ _stripeLen;
    for (var stripe = 0; stripe < stripes; stripe++) {
      _accumulate512(
        acc,
        input,
        blocks * blockLen + stripe * _stripeLen,
        stripe * _secretConsumeRate,
      );
    }
    _accumulate512(
      acc,
      input,
      len - _stripeLen,
      secretSize - _stripeLen - _secretLastAccStart,
    );
    final low = _mergeAccs(acc, _secretMergeAccsStart, len * _prime64_1);
    final high = _mergeAccs(
      acc,
      secretSize - 64 - _secretMergeAccsStart,
      ~(len * _prime64_2),
    );
    return (high, low);
  }

  static String _hex64(int v) =>
      (v >>> 32).toRadixString(16).padLeft(8, '0') +
      (v & _mask32).toRadixString(16).padLeft(8, '0');
}
