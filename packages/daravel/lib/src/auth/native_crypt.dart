import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

typedef _CryptRnNative = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Void>,
  Int32,
);
typedef _CryptRn = Pointer<Utf8> Function(
  Pointer<Utf8>,
  Pointer<Utf8>,
  Pointer<Void>,
  int,
);

/// The system's `crypt_rn` (libxcrypt, `libcrypt.so.1`): the C bcrypt
/// that PHP's `password_hash` also runs, about 1.5 times as fast as Dart.
///
/// Linux only; there it ships with every distribution (it is part of the
/// base system of Debian, Ubuntu, Alpine's libxcrypt, RHEL). Elsewhere, or
/// when the library is missing, [available] is false and callers use the
/// Dart implementation. `crypt_rn` keeps its state in a buffer per call,
/// so isolates may call it at the same time.
abstract final class NativeCrypt {
  static final _CryptRn? _cryptRn = _load();

  /// `struct crypt_data` is 32 KiB in libxcrypt.
  static const int _dataSize = 32768;

  static _CryptRn? _load() {
    if (!Platform.isLinux ||
        Platform.environment['DARAVEL_NATIVE_CRYPT'] == 'false') {
      return null;
    }
    try {
      return DynamicLibrary.open('libcrypt.so.1')
          .lookupFunction<_CryptRnNative, _CryptRn>('crypt_rn');
    } on Object {
      return null;
    }
  }

  /// Whether `crypt_rn` was found.
  static bool get available => _cryptRn != null;

  /// `crypt(3)` of [phrase] with [setting] (`$2y$10$<22-char salt>`, or a
  /// whole hash to verify against); null when the library is not there or
  /// rejects the setting.
  static String? crypt(String phrase, String setting) {
    final cryptRn = _cryptRn;
    if (cryptRn == null) {
      return null;
    }
    final phrasePointer = phrase.toNativeUtf8();
    final settingPointer = setting.toNativeUtf8();
    final data = calloc<Uint8>(_dataSize);
    try {
      final result = cryptRn(
        phrasePointer,
        settingPointer,
        data.cast(),
        _dataSize,
      );
      if (result == nullptr) {
        return null;
      }
      final text = result.toDartString();
      // libxcrypt's failure tokens start with '*'.
      return text.startsWith('*') ? null : text;
    } finally {
      // The buffer holds state derived from the password.
      data.asTypedList(_dataSize).fillRange(0, _dataSize, 0);
      calloc
        ..free(phrasePointer)
        ..free(settingPointer)
        ..free(data);
    }
  }
}
