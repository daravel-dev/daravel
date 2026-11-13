import 'dart:convert';

import 'auth.dart';

/// An authorizer holding something to release ([EchoAuth.bearer] and
/// [EchoAuth.endpoint] keep one HTTP client): `Echo.disconnect` closes it.
/// Not exported.
abstract interface class ClosableEchoAuth {
  /// Releases what the authorizer holds; it can be used again afterwards.
  void close();
}

/// [answer] as the authorization of [channel], or [EchoAuthException] with
/// [status] (0 when no HTTP answer is behind it) naming what is wrong: a
/// JSON object with a string `auth`, `channel_data` a string when given,
/// and for an encrypted channel a `shared_secret` that is the base64 of a
/// 32-byte key (a key of another length subscribed, and then every event
/// failed to open).
Map<String, Object?> checkedAuthorization(
  String channel,
  Object? answer,
  int status,
) {
  if (answer is! Map<String, Object?>) {
    throw EchoAuthException(channel, status, 'not a JSON object');
  }
  if (answer['auth'] is! String) {
    throw EchoAuthException(channel, status, 'no auth');
  }
  final data = answer['channel_data'];
  if (data != null && data is! String) {
    throw EchoAuthException(channel, status, 'channel_data is not a string');
  }
  if (channel.startsWith('private-encrypted-')) {
    final secret = answer['shared_secret'];
    if (secret is! String) {
      throw EchoAuthException(channel, status, 'no shared_secret');
    }
    final List<int> key;
    try {
      key = base64.decode(secret);
    } on FormatException {
      throw EchoAuthException(channel, status, 'shared_secret is not base64');
    }
    if (key.length != 32) {
      throw EchoAuthException(
        channel,
        status,
        'shared_secret is ${key.length} bytes, not 32',
      );
    }
  }
  return answer;
}
