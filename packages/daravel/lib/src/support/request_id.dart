import 'dart:math';

/// Generates opaque, URL-safe request identifiers.
final class RequestId {
  const RequestId._();

  static final Random _random = Random.secure();

  /// 24 hex characters (96 bits of entropy).
  static String generate() {
    final buffer = StringBuffer();
    for (var i = 0; i < 12; i++) {
      buffer.write(_random.nextInt(256).toRadixString(16).padLeft(2, '0'));
    }
    return buffer.toString();
  }
}
