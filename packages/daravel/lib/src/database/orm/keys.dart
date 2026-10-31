import 'dart:math';

import '../../foundation/clock.dart';

import 'package:uuid/uuid.dart';

/// Primary key strategies.
enum KeyType {
  /// Database generated auto-increment integer.
  autoInt,

  /// Client generated UUID v4 (string).
  uuid,

  /// Client generated ULID (26 chars, lexicographically sortable).
  ulid,

  /// Application supplied string key.
  string,

  /// Application supplied integer key (Laravel's
  /// `$incrementing = false`): nothing is generated or read back, and
  /// saving a new model without one is an error.
  manualInt,
}

/// Generates client-side keys.
abstract final class KeyGenerator {
  static const Uuid _uuid = Uuid();
  static final Random _random = Random.secure();
  static const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  static String uuid() => _uuid.v4();

  /// Crockford base32 ULID: 10 chars timestamp + 16 chars randomness.
  static String ulid([DateTime? now]) {
    var time = (now ?? Clock.now()).toUtc().millisecondsSinceEpoch;
    final chars = List<String>.filled(26, '0');
    for (var i = 9; i >= 0; i--) {
      chars[i] = _alphabet[time & 0x1f];
      time >>= 5;
    }
    for (var i = 10; i < 26; i++) {
      chars[i] = _alphabet[_random.nextInt(32)];
    }
    return chars.join();
  }
}
