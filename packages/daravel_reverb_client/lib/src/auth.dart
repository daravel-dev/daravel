import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

/// How a private, encrypted or presence channel is authorized: Laravel's
/// `/broadcasting/auth` (or Daravel's), answered with `auth`, and for
/// presence `channel_data`, for encrypted channels `shared_secret`.
abstract interface class EchoAuth {
  /// POSTs `socket_id` and `channel_name` (a form, as Laravel Echo does) to
  /// [endpoint] with `Authorization: Bearer <token>` when [token] gives one.
  factory EchoAuth.bearer(
    FutureOr<String?> Function() token, {
    required String endpoint,
    Map<String, String> headers,
    http.Client? client,
  }) = _HttpAuth;

  /// POSTs to [endpoint] with [headers] (a session cookie, say).
  factory EchoAuth.endpoint(
    String endpoint, {
    Map<String, String> headers,
    http.Client? client,
  }) = _HttpAuth.plain;

  /// Asks [authorize], which answers the auth response's JSON map.
  factory EchoAuth.custom(
    FutureOr<Map<String, Object?>> Function(String socketId, String channel)
    authorize,
  ) = _CustomAuth;

  /// The auth response for [channel] of connection [socketId].
  Future<Map<String, Object?>> authorize(String socketId, String channel);
}

/// The auth endpoint refused or failed.
final class EchoAuthException implements Exception {
  /// Authorizing [channel] failed with [status] (0: no answer).
  const EchoAuthException(this.channel, this.status, [this.message = '']);

  /// The channel.
  final String channel;

  /// The HTTP status, or 0.
  final int status;

  /// More about it.
  final String message;

  @override
  String toString() =>
      'EchoAuthException: $channel ($status)${message.isEmpty ? '' : ': $message'}';
}

final class _HttpAuth implements EchoAuth {
  _HttpAuth(
    FutureOr<String?> Function() token, {
    required this.endpoint,
    this.headers = const {},
    this.client,
  }) : _token = token;

  _HttpAuth.plain(this.endpoint, {this.headers = const {}, this.client})
    : _token = null;

  final String endpoint;
  final Map<String, String> headers;
  final http.Client? client;
  final FutureOr<String?> Function()? _token;

  @override
  Future<Map<String, Object?>> authorize(
    String socketId,
    String channel,
  ) async {
    final token = await _token?.call();
    final requestHeaders = {
      'accept': 'application/json',
      ...headers,
      if (token != null && token.isNotEmpty) 'authorization': 'Bearer $token',
    };
    final body = {'socket_id': socketId, 'channel_name': channel};
    final http.Response response;
    try {
      final own = client;
      response = own == null
          ? await http.post(
              Uri.parse(endpoint),
              headers: requestHeaders,
              body: body,
            )
          : await own.post(
              Uri.parse(endpoint),
              headers: requestHeaders,
              body: body,
            );
    } on Object catch (error) {
      throw EchoAuthException(channel, 0, '$error');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw EchoAuthException(channel, response.statusCode);
    }
    final decoded = jsonDecode(response.body);
    if (decoded is! Map<String, Object?> || decoded['auth'] is! String) {
      throw EchoAuthException(channel, response.statusCode, 'no auth');
    }
    return decoded;
  }
}

final class _CustomAuth implements EchoAuth {
  _CustomAuth(this._authorize);

  final FutureOr<Map<String, Object?>> Function(String, String) _authorize;

  @override
  Future<Map<String, Object?>> authorize(
    String socketId,
    String channel,
  ) async => await _authorize(socketId, channel);
}
