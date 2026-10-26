import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../foundation/clock.dart';
import '../auth/hashing.dart' show constantTimeEquals;

/// The Pusher protocol's signatures, as `pusher/pusher-php-server` and
/// Laravel Reverb compute them.
abstract final class PusherSignature {
  static String _hmac(String secret, String text) =>
      Hmac(sha256, utf8.encode(secret)).convert(utf8.encode(text)).toString();

  /// The answer to a client asking to join a private or presence channel
  /// (Laravel's `/broadcasting/auth`): `{"auth": "<key>:<hmac>"}`, plus
  /// `channel_data` for a presence channel.
  static Map<String, String> authorizeChannel({
    required String key,
    required String secret,
    required String socketId,
    required String channel,
    String? channelData,
  }) => {
    'auth':
        '$key:${_hmac(secret, channelData == null ? '$socketId:$channel' : '$socketId:$channel:$channelData')}',
    'channel_data': ?channelData,
  };

  /// Whether [auth] (`<key>:<hmac>`) authorizes [socketId] on [channel].
  static bool verifyChannel({
    required String secret,
    required String socketId,
    required String channel,
    required String? auth,
    String? channelData,
  }) {
    if (auth == null) {
      return false;
    }
    final expected = _hmac(
      secret,
      channelData == null || channelData.isEmpty
          ? '$socketId:$channel'
          : '$socketId:$channel:$channelData',
    );
    final colon = auth.indexOf(':');
    return constantTimeEquals(
      expected,
      colon < 0 ? auth : auth.substring(colon + 1),
    );
  }

  /// The query of a signed API request (`auth_key`, `auth_timestamp`,
  /// `auth_version`, `body_md5`, `auth_signature`).
  static Map<String, String> signRequest({
    required String key,
    required String secret,
    required String method,
    required String path,
    String body = '',
    Map<String, String> query = const {},
  }) {
    final params = <String, String>{
      ...query,
      'auth_key': key,
      'auth_timestamp': '${Clock.now().millisecondsSinceEpoch ~/ 1000}',
      'auth_version': '1.0',
      if (body.isNotEmpty)
        'body_md5': md5.convert(utf8.encode(body)).toString(),
    };
    return {
      ...params,
      'auth_signature': _hmac(secret, _stringToSign(method, path, params)),
    };
  }

  /// Whether an API request is signed with [secret] (Reverb's
  /// `Controller::verifySignature`): `body_md5` is computed from [body],
  /// not taken from the query.
  static bool verifyRequest({
    required String secret,
    required String method,
    required String path,
    required Map<String, String> query,
    required String body,
  }) {
    // As Pusher Channels (Reverb does not check): a signed request older or
    // newer than 10 minutes is refused, so a captured one cannot be
    // replayed later.
    final timestamp = int.tryParse(query['auth_timestamp'] ?? '');
    final now = Clock.now().millisecondsSinceEpoch ~/ 1000;
    if (timestamp == null || (now - timestamp).abs() > 600) {
      return false;
    }
    final params = Map.of(query)
      ..remove('auth_signature')
      ..remove('body_md5');
    if (body.isNotEmpty) {
      params['body_md5'] = md5.convert(utf8.encode(body)).toString();
    }
    final expected = _hmac(secret, _stringToSign(method, path, params));
    return constantTimeEquals(expected, query['auth_signature'] ?? '');
  }

  static String _stringToSign(
    String method,
    String path,
    Map<String, String> params,
  ) {
    final keys = params.keys.toList()..sort();
    return '$method\n$path\n${keys.map((k) => '$k=${params[k]}').join('&')}';
  }
}
