import 'dart:math';

/// Generates opaque, URL-safe request identifiers.
final class RequestId {
  const RequestId._();

  static final Random _random = Random.secure();

  /// 24 hex characters (96 bits of entropy), drawn as three 32-bit values:
  /// each `Random.secure()` call reads from the OS, so fewer calls matter on
  /// a per-request path.
  static String generate() => _word() + _word() + _word();

  static String _word() =>
      _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
}
