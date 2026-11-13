import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'auth_support.dart';

/// How a private, encrypted or presence channel is authorized: Laravel's
/// `/broadcasting/auth` (or Daravel's), answered with `auth`, and for
/// presence `channel_data`, for encrypted channels `shared_secret`.
abstract interface class EchoAuth {
  /// POSTs `socket_id` and `channel_name` (a form, as Laravel Echo does) to
  /// [endpoint] with `Authorization: Bearer <token>` when [token] gives one.
  ///
  /// A request that takes longer than [timeout] fails the authorization
  /// (status 0, `timeout`). Without a [client], one is made when first
  /// needed, used for every authorization and closed by `Echo.disconnect`.
  factory EchoAuth.bearer(
    FutureOr<String?> Function() token, {
    required String endpoint,
    Map<String, String> headers,
    http.Client? client,
    Duration timeout,
  }) = _HttpAuth;

  /// POSTs to [endpoint] with [headers] (a session cookie, say); [timeout]
  /// and the client as for [EchoAuth.bearer].
  factory EchoAuth.endpoint(
    String endpoint, {
    Map<String, String> headers,
    http.Client? client,
    Duration timeout,
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
  /// Authorizing [channel] failed with [status] (0: no HTTP answer, as for
  /// a timeout or an [EchoAuth.custom] authorizer).
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

final class _HttpAuth implements EchoAuth, ClosableEchoAuth {
  _HttpAuth(
    FutureOr<String?> Function() token, {
    required this.endpoint,
    this.headers = const {},
    this.client,
    this.timeout = const Duration(seconds: 30),
  }) : _token = token;

  _HttpAuth.plain(
    this.endpoint, {
    this.headers = const {},
    this.client,
    this.timeout = const Duration(seconds: 30),
  }) : _token = null;

  final String endpoint;
  final Map<String, String> headers;
  final http.Client? client;
  final Duration timeout;
  final FutureOr<String?> Function()? _token;

  /// The client made here when none was given: kept for the next
  /// authorizations, closed by [close].
  http.Client? _own;

  @override
  void close() {
    _own?.close();
    _own = null;
  }

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
      response = await (client ?? (_own ??= http.Client()))
          .post(Uri.parse(endpoint), headers: requestHeaders, body: body)
          .timeout(timeout);
    } on TimeoutException {
      throw EchoAuthException(channel, 0, 'timeout');
    } on Object catch (error) {
      throw EchoAuthException(channel, 0, '$error');
    }
    final status = response.statusCode;
    if (status < 200 || status >= 300) {
      throw EchoAuthException(channel, status);
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      // A login page, an empty body: the status alone said yes.
      throw EchoAuthException(channel, status, 'invalid json');
    }
    return checkedAuthorization(channel, decoded, status);
  }
}

final class _CustomAuth implements EchoAuth {
  _CustomAuth(this._authorize);

  final FutureOr<Map<String, Object?>> Function(String, String) _authorize;

  @override
  Future<Map<String, Object?>> authorize(
    String socketId,
    String channel,
  ) async =>
      checkedAuthorization(channel, await _authorize(socketId, channel), 0);
}
