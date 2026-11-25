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
  /// An authorization that takes longer than [timeout] fails (status 0,
  /// `timeout`). Without a [client], one is made when first needed, used
  /// for every authorization and closed by `Echo.disconnect` and when the
  /// connection is lost; a request that fails before any answer began (a
  /// keep-alive socket the server closed) is then sent once more, within
  /// the same [timeout]. A [client] that is given is asked once and never
  /// closed.
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

  /// The socket ids of connections that are gone, oldest first: an
  /// authorization for one of them sends nothing more. Only the last
  /// [_goneKept] are kept, which is enough: an authorization lasts
  /// [timeout] at most. Other connections sharing this authorizer are not
  /// in it, and go on.
  final Set<String> _gone = {};
  static const int _goneKept = 16;

  /// The clients made for a second request, each with the socket id it
  /// authorizes for, while that request is on its way.
  final Map<http.Client, String> _second = {};

  @override
  void close(String? socketId) {
    if (socketId != null) {
      _gone
        ..remove(socketId)
        ..add(socketId);
      if (_gone.length > _goneKept) {
        _gone.remove(_gone.first);
      }
      _second.removeWhere((client, id) {
        if (id != socketId) {
          return false;
        }
        client.close();
        return true;
      });
    }
    _own?.close();
    _own = null;
  }

  /// [sending] within [limit], or a [TimeoutException]. A response that
  /// arrives after that has no reader, and would keep its socket and what
  /// the server still writes to it: it is read to its end and dropped,
  /// without waiting for it, and so is the error it may end with. (A
  /// `Response.fromStream` that runs out of time needs no such care: it
  /// goes on reading its body to the end, and `timeout` drops its result.)
  static Future<http.StreamedResponse> _within(
    Future<http.StreamedResponse> sending,
    Duration limit,
  ) => sending.timeout(
    limit,
    onTimeout: () {
      sending
          .then((late) => late.stream.drain<void>())
          .catchError((Object _) {})
          .ignore();
      throw TimeoutException(null);
    },
  );

  @override
  Future<Map<String, Object?>> authorize(
    String socketId,
    String channel,
  ) async {
    final token = await _token?.call();
    if (_gone.contains(socketId)) {
      throw EchoAuthException(channel, 0, 'closed');
    }
    final requestHeaders = {
      'accept': 'application/json',
      ...headers,
      if (token != null && token.isNotEmpty) 'authorization': 'Bearer $token',
    };
    final uri = Uri.parse(endpoint);
    http.Request request() => http.Request('POST', uri)
      ..headers.addAll(requestHeaders)
      ..bodyFields = {'socket_id': socketId, 'channel_name': channel};
    // One deadline for the whole authorization, a second request included.
    final elapsed = Stopwatch()..start();
    Duration left() {
      final left = timeout - elapsed.elapsed;
      return left > Duration.zero ? left : Duration.zero;
    }

    final http.Response response;
    http.Client? second;
    try {
      http.StreamedResponse answered;
      try {
        answered = await _within(
          (client ?? (_own ??= http.Client())).send(request()),
          left(),
        );
      } on http.ClientException {
        // No answer began: a pooled keep-alive socket closed by a draining
        // worker or proxy fails like this, and so does a request on the
        // shared client when [close] closes it for another connection.
        // Authorizing is idempotent, so the request is sent once more, on
        // a client made for it alone: the shared one stays as it is for
        // the requests still using it. A client the application gave is
        // not asked twice, and nothing is sent for a connection that is
        // gone.
        if (client != null || _gone.contains(socketId)) {
          rethrow;
        }
        if (left() == Duration.zero) {
          throw TimeoutException(null);
        }
        second = http.Client();
        _second[second] = socketId;
        answered = await _within(second.send(request()), left());
      }
      // The endpoint answered: a body that fails from here on is an error,
      // not a reason to ask again.
      response = await http.Response.fromStream(answered).timeout(left());
    } on TimeoutException {
      throw EchoAuthException(channel, 0, 'timeout');
    } on Object catch (error) {
      throw EchoAuthException(channel, 0, '$error');
    } finally {
      if (second != null) {
        _second.remove(second);
        second.close();
      }
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
