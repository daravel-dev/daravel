import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A Pusher protocol 7 server in the test's process: it greets each client
/// with `pusher:connection_established`, confirms subscriptions (presence
/// with [presence] as the members), records every frame clients send, and
/// answers `POST /broadcasting/auth` with [authorize].
final class FakePusher {
  FakePusher._(this._server);

  /// Starts the server on a free loopback port.
  static Future<FakePusher> start() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakePusher._(server);
    server.listen(fake._handle);
    return fake;
  }

  final HttpServer _server;

  /// The port.
  int get port => _server.port;

  /// `ws://127.0.0.1:<port>`.
  String get host => 'ws://127.0.0.1:$port';

  /// The auth endpoint.
  String get authEndpoint => 'http://127.0.0.1:$port/broadcasting/auth';

  /// Sent with `pusher:connection_established`.
  int activityTimeout = 120;

  /// When set, sent as the `activity_timeout` JSON text as it is (`0`,
  /// `1e400`), in place of [activityTimeout].
  String? activityTimeoutJson;

  /// How long a subscription waits for its
  /// `pusher_internal:subscription_succeeded`.
  Duration confirmDelay = Duration.zero;

  /// The members a presence subscription starts with (`user_id` →
  /// `user_info`).
  Map<String, Map<String, Object?>> presence = {};

  /// Answers the auth endpoint: `(headers, form) → (status, body)`.
  (int, Map<String, Object?>) Function(
    HttpHeaders headers,
    Map<String, String> form,
  )
  authorize = (_, form) => (200, {'auth': 'key:signature'});

  /// Every frame clients sent, in order.
  final List<Map<String, Object?>> received = [];

  /// The URLs clients connected to.
  final List<Uri> connections = [];

  /// The open sockets.
  final List<WebSocket> sockets = [];

  /// The auth requests, as their forms.
  final List<Map<String, String>> authRequests = [];

  int _ids = 0;

  /// Sends [frame] to every client.
  void broadcast(Map<String, Object?> frame) {
    final text = jsonEncode(frame);
    for (final socket in sockets) {
      socket.add(text);
    }
  }

  /// Sends event [event] on [channel] with [data] (as JSON text, as Pusher
  /// servers send it).
  void event(String channel, String event, Object? data) => broadcast({
    'event': event,
    'channel': channel,
    'data': data is String ? data : jsonEncode(data),
  });

  /// Closes every client connection with [code].
  Future<void> drop([int? code]) async {
    for (final socket in [...sockets]) {
      await socket.close(code);
    }
    sockets.clear();
  }

  /// Waits for a frame matching [test] from a client.
  Future<Map<String, Object?>> next(
    bool Function(Map<String, Object?> frame) test, {
    int skip = 0,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      final matches = received.where(test).toList();
      if (matches.length > skip) {
        return matches[skip];
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    throw TimeoutException('No matching frame; got $received');
  }

  /// Stops the server.
  Future<void> close() async {
    await drop();
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    if (request.uri.path == '/broadcasting/auth') {
      final body = await utf8.decodeStream(request);
      final form = Uri.splitQueryString(body);
      authRequests.add(form);
      final (status, answer) = authorize(request.headers, form);
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(answer));
      await request.response.close();
      return;
    }
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = 404;
      await request.response.close();
      return;
    }
    connections.add(request.uri);
    final socket = await WebSocketTransformer.upgrade(request);
    sockets.add(socket);
    final socketId = '${++_ids}.${1000 + _ids}';
    socket
      ..add(
        jsonEncode({
          'event': 'pusher:connection_established',
          'data': activityTimeoutJson == null
              ? jsonEncode({
                  'socket_id': socketId,
                  'activity_timeout': activityTimeout,
                })
              : '{"socket_id":"$socketId",'
                    '"activity_timeout":$activityTimeoutJson}',
        }),
      )
      ..listen((Object? message) async {
        final frame = jsonDecode(message! as String) as Map<String, Object?>;
        received.add(frame);
        if (frame['event'] == 'pusher:subscribe') {
          final data = frame['data']! as Map<String, Object?>;
          final channel = data['channel']! as String;
          if (confirmDelay > Duration.zero) {
            await Future<void>.delayed(confirmDelay);
          }
          socket.add(
            jsonEncode({
              'event': 'pusher_internal:subscription_succeeded',
              'channel': channel,
              'data': jsonEncode(
                channel.startsWith('presence-')
                    ? {
                        'presence': {
                          'ids': presence.keys.toList(),
                          'hash': presence,
                          'count': presence.length,
                        },
                      }
                    : <String, Object?>{},
              ),
            }),
          );
        }
      }, onDone: () => sockets.remove(socket));
  }
}
