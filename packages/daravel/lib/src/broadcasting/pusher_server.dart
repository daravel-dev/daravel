import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../http/request.dart';
import '../http/response.dart';
import '../server/broadcast.dart';
import '../server/coordinator.dart';
import 'broadcast_config.dart';
import 'cluster.dart';
import 'pusher_signature.dart';

/// A Pusher protocol server (version 7), as Laravel Reverb is: Laravel
/// Echo and pusher-js connect to `/app/{key}`, and Laravel (or anything
/// with a Pusher HTTP client) publishes through `/apps/{id}/events`.
///
/// Messages reach the connections of every worker isolate through the
/// [Broadcaster]; who is on which channel, and a presence channel's
/// members, live in the coordinator (`ChannelMembershipService`). With
/// several servers (`REVERB_SCALING_ENABLED`), [state] and [relay] share
/// both through the database instead.
final class PusherServer {
  PusherServer(
    this.config,
    this._broadcaster,
    CoordinatorChannel coordinator, {
    ChannelState? state,
    this.relay,
  }) : _state = state ?? _CoordinatorChannelState(coordinator);

  final BroadcastConfig config;
  final Broadcaster _broadcaster;
  final ChannelState _state;

  /// Carries frames to the other servers, and theirs to this one.
  final DatabaseBroadcastRelay? relay;

  /// Starts reading the other servers' frames (once, at the first client).
  Future<void>? _relaying;

  /// Stops relaying (application shutdown).
  Future<void> close() async => relay?.close();

  static final Random _random = Random.secure();

  /// Publishes [event] with [data] (a string, sent as it is, or anything
  /// else as JSON) to [channels], except to the connection [exceptSocket].
  Future<void> publish(
    String event,
    List<String> channels,
    Object? data, {
    String? exceptSocket,
  }) async {
    final text = data is String ? data : jsonEncode(data);
    for (final channel in channels) {
      await _send(channel, {
        'event': event,
        'channel': channel,
        'data': text,
      }, exceptSocket);
    }
  }

  /// One frame, encoded once, to every connection on [channel] but
  /// [except]: `<socket id>\n<frame>`. A cache channel also keeps it for
  /// the next subscribers, unless [internal] (member_added and _removed).
  Future<void> _send(
    String channel,
    Map<String, Object?> frame,
    String? except, {
    bool internal = false,
  }) async {
    final text = jsonEncode(frame);
    if (!internal && isCacheChannel(channel)) {
      await _call('cache_set', {'channel': channel, 'frame': text});
    }
    final envelope = '${except ?? ''}\n$text';
    await _broadcaster.publish(channel, envelope);
    await relay?.send(channel, envelope);
  }

  /// `cache-…`, `private-cache-…` and `presence-cache-…` channels.
  static bool isCacheChannel(String channel) =>
      channel.startsWith('cache-') ||
      channel.startsWith('private-cache-') ||
      channel.startsWith('presence-cache-');

  Future<Object?> _call(String op, Map<String, Object?> args) =>
      _state.call(op, args);

  // ---------------------------------------------------------------------
  // WebSocket connections (`/app/{key}`).

  /// Serves one client connection until it closes.
  Future<void> connect(WebSocket socket, Request request, String appKey) async {
    if (appKey != config.appKey) {
      socket.add(_error(4001, 'Application does not exist'));
      await socket.close();
      return;
    }
    if (!_originAllowed(request.header('origin'))) {
      socket.add(_error(4009, 'Origin not allowed'));
      await socket.close();
      return;
    }
    final relay = this.relay;
    if (relay != null) {
      await (_relaying ??= relay.start(_broadcaster.deliverLocally));
    }
    final connection = _Connection(
      this,
      socket,
      '${_random.nextInt(1000000000) + 1}.${_random.nextInt(1000000000) + 1}',
    );
    socket.pingInterval = Duration(seconds: config.activityTimeout);
    connection.send(
      jsonEncode({
        'event': 'pusher:connection_established',
        'data': jsonEncode({
          'socket_id': connection.id,
          'activity_timeout': config.activityTimeout,
        }),
      }),
    );
    try {
      await for (final message in socket) {
        await connection.receive(message);
      }
    } on Object {
      // The connection dropped.
    } finally {
      await connection.close();
    }
  }

  bool _originAllowed(String? origin) {
    if (config.allowedOrigins.contains('*')) {
      return true;
    }
    final host = origin == null ? null : Uri.tryParse(origin)?.host;
    if (host == null || host.isEmpty) {
      return false;
    }
    return config.allowedOrigins.any(
      (pattern) =>
          RegExp('^${pattern.split('*').map(RegExp.escape).join('.*')}\$')
              .hasMatch(host),
    );
  }

  static String _error(int code, String message) => jsonEncode({
    'event': 'pusher:error',
    'data': jsonEncode({'code': code, 'message': message}),
  });

  // ---------------------------------------------------------------------
  // The HTTP API (`/apps/{id}/...`), signed with the app secret.

  Future<Response?> _verify(Request request, String appId) async {
    if (appId != config.appId || !config.serves) {
      return Response.json({
        'message': 'No matching application for ID [$appId].',
      }, status: 404);
    }
    final body = utf8.decode(await request.bytes(), allowMalformed: true);
    if (!PusherSignature.verifyRequest(
      secret: config.appSecret,
      method: request.method,
      path: request.path,
      query: request.query,
      body: body,
    )) {
      return Response.json({
        'message': 'Authentication signature invalid.',
      }, status: 401);
    }
    return null;
  }

  Future<Map<String, Object?>?> _json(Request request) async {
    try {
      final decoded = jsonDecode(utf8.decode(await request.bytes()));
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  /// `POST /apps/{id}/events`: `{"name", "data", "channels" | "channel",
  /// "socket_id"?}`, as Pusher's HTTP clients send it.
  Future<Response> events(Request request, String appId) async {
    final refused = await _verify(request, appId);
    if (refused != null) {
      return refused;
    }
    final body = await _json(request);
    final name = body?['name'];
    final data = body?['data'];
    final channels = switch (body?['channels'] ?? body?['channel']) {
      final String channel => [channel],
      final List<Object?> list => [for (final c in list) '$c'],
      _ => null,
    };
    if (name is! String || data is! String || channels == null) {
      return _invalid('name, data and channels (or channel) are required.');
    }
    await publish(
      name,
      channels,
      data,
      exceptSocket: body?['socket_id'] as String?,
    );
    return Response.json(<String, Object?>{});
  }

  /// `POST /apps/{id}/batch_events`: `{"batch": [{"name", "data",
  /// "channel", "socket_id"?}, ...]}`.
  Future<Response> batchEvents(Request request, String appId) async {
    final refused = await _verify(request, appId);
    if (refused != null) {
      return refused;
    }
    final batch = (await _json(request))?['batch'];
    if (batch is! List<Object?> ||
        batch.any(
          (item) =>
              item is! Map<String, Object?> ||
              item['name'] is! String ||
              item['data'] is! String ||
              item['channel'] is! String,
        )) {
      return _invalid('Each batch item needs name, data and channel.');
    }
    for (final item in batch.cast<Map<String, Object?>>()) {
      await publish(
        item['name']! as String,
        [item['channel']! as String],
        item['data'],
        exceptSocket: item['socket_id'] as String?,
      );
    }
    return Response.json({'batch': <String, Object?>{}});
  }

  /// `GET /apps/{id}/channels?filter_by_prefix=&info=user_count`.
  Future<Response> channels(Request request, String appId) async {
    final refused = await _verify(request, appId);
    if (refused != null) {
      return refused;
    }
    final prefix = request.query['filter_by_prefix'] ?? '';
    final userCount = (request.query['info'] ?? '').contains('user_count');
    final counts =
        (await _call('channels', {'prefix': prefix}))! as Map<Object?, Object?>;
    final out = <String, Object?>{};
    for (final name in counts.keys.cast<String>()) {
      out[name] = userCount && name.startsWith('presence-')
          ? {
              'user_count':
                  ((await _call('channel', {'channel': name}))!
                      as Map)['user_count'],
            }
          : <String, Object?>{};
    }
    return Response.json({'channels': out});
  }

  /// `GET /apps/{id}/channels/{channel}?info=user_count,subscription_count`.
  Future<Response> channel(Request request, String appId, String name) async {
    final refused = await _verify(request, appId);
    if (refused != null) {
      return refused;
    }
    final info = (await _call('channel', {'channel': name}))! as Map;
    final wanted = (request.query['info'] ?? '').split(',');
    return Response.json({
      'occupied': info['occupied'],
      if (wanted.contains('subscription_count'))
        'subscription_count': info['subscription_count'],
      if (wanted.contains('user_count') && name.startsWith('presence-'))
        'user_count': info['user_count'],
    });
  }

  /// `GET /apps/{id}/channels/{channel}/users` (presence channels).
  Future<Response> users(Request request, String appId, String name) async {
    final refused = await _verify(request, appId);
    if (refused != null) {
      return refused;
    }
    if (!name.startsWith('presence-')) {
      return _invalid('Only presence channels have users.');
    }
    final ids = (await _call('users', {'channel': name}))! as List;
    return Response.json({
      'users': [
        for (final id in ids) {'id': id},
      ],
    });
  }

  static Response _invalid(String message) =>
      Response.json({'message': message}, status: 422);
}

/// The coordinator's `ChannelMembershipService`: one server, every isolate.
final class _CoordinatorChannelState implements ChannelState {
  _CoordinatorChannelState(this._coordinator);

  final CoordinatorChannel _coordinator;

  @override
  Future<Object?> call(String op, Map<String, Object?> args) =>
      _coordinator.call('channels', op, args);
}

/// One client connection.
final class _Connection {
  _Connection(this._server, this._socket, this.id);

  final PusherServer _server;
  final WebSocket _socket;

  /// The socket id (`123.456`): signed into channel authorizations and
  /// sent as `X-Socket-ID` for `toOthers()`.
  final String id;

  final Map<String, BroadcastSubscription> _subscriptions = {};

  void send(String text) {
    if (_socket.closeCode == null) {
      _socket.add(text);
    }
  }

  void _error(int code, String message) =>
      send(PusherServer._error(code, message));

  Future<void> receive(Object? message) async {
    if (message is! String ||
        utf8.encode(message).length > _server.config.maxMessageSize) {
      return _error(4200, 'Invalid message format');
    }
    final Map<String, Object?> payload;
    try {
      final decoded = jsonDecode(message);
      if (decoded is! Map<String, Object?> || decoded['event'] is! String) {
        return _error(4200, 'Invalid message format');
      }
      payload = decoded;
    } on FormatException {
      return _error(4200, 'Invalid message format');
    }
    final event = payload['event']! as String;
    // pusher-js sends `data` as an object; some clients as a JSON string.
    final data = switch (payload['data']) {
      final Map<String, Object?> map => map,
      final String text when text.isNotEmpty => _decodeMap(text),
      _ => const <String, Object?>{},
    };
    switch (event) {
      case 'pusher:ping':
        send(jsonEncode({'event': 'pusher:pong'}));
      case 'pusher:pong':
        break;
      case 'pusher:subscribe':
        final channel = data['channel'];
        if (channel is! String || channel.isEmpty) {
          return _error(4200, 'Invalid message format');
        }
        await _subscribe(
          channel,
          data['auth'] as String?,
          data['channel_data'] as String?,
        );
      case 'pusher:unsubscribe':
        final channel = data['channel'];
        if (channel is String) {
          await _unsubscribe(channel);
        }
      case _ when event.startsWith('pusher:'):
        _error(4200, 'Invalid message format');
      case _ when event.startsWith('client-'):
        await _whisper(event, payload);
    }
  }

  static Map<String, Object?> _decodeMap(String text) {
    try {
      final decoded = jsonDecode(text);
      return decoded is Map<String, Object?> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }

  Future<void> _subscribe(
    String channel,
    String? auth,
    String? channelData,
  ) async {
    final presence = channel.startsWith('presence-');
    final guarded = presence || channel.startsWith('private-');
    if (guarded &&
        !PusherSignature.verifyChannel(
          secret: _server.config.appSecret,
          socketId: id,
          channel: channel,
          auth: auth,
          channelData: channelData,
        )) {
      return _error(4009, 'Connection is unauthorized');
    }
    String? userId;
    Object? userInfo;
    if (presence) {
      final member = channelData == null ? null : _decodeMap(channelData);
      userId = switch (member?['user_id']) {
        null => null,
        final Object id => '$id',
      };
      userInfo = member?['user_info'];
    }
    if (!_subscriptions.containsKey(channel)) {
      final subscription = await _server._broadcaster.subscribe(channel);
      subscription.messages.listen((envelope) {
        final newline = envelope.indexOf('\n');
        // `<except>\n<frame>`: not to the connection that sent it.
        if (envelope.substring(0, newline) != id) {
          send(envelope.substring(newline + 1));
        }
      });
      _subscriptions[channel] = subscription;
    }
    final joined =
        (await _server._call('join', {
              'channel': channel,
              'socket': id,
              'user_id': userId,
              'user_info': userInfo,
            }))!
            as Map;
    final members = joined['members'] as Map?;
    send(
      jsonEncode({
        'event': 'pusher_internal:subscription_succeeded',
        'data': jsonEncode(
          presence
              ? {
                  'presence': {
                    'count': members?.length ?? 0,
                    'ids': members?.keys.toList() ?? const [],
                    'hash': members ?? const {},
                  },
                }
              : <String, Object?>{},
        ),
        'channel': channel,
      }),
    );
    if (PusherServer.isCacheChannel(channel)) {
      final cached = await _server._call('cache_get', {'channel': channel});
      send(
        cached is String
            ? cached
            : jsonEncode({'event': 'pusher:cache_miss', 'channel': channel}),
      );
    }
    if (joined['added'] == true) {
      await _server._send(
        channel,
        {
          'event': 'pusher_internal:member_added',
          'data': jsonEncode({'user_id': userId, 'user_info': ?userInfo}),
          'channel': channel,
        },
        id,
        internal: true,
      );
    }
  }

  Future<void> _unsubscribe(String channel) async {
    final subscription = _subscriptions.remove(channel);
    if (subscription == null) {
      return;
    }
    await subscription.cancel();
    final left =
        (await _server._call('leave', {'channel': channel, 'socket': id}))!
            as Map;
    final removed = left['removed'];
    if (removed != null) {
      await _server._send(
        channel,
        {
          'event': 'pusher_internal:member_removed',
          'data': jsonEncode({'user_id': removed}),
          'channel': channel,
        },
        id,
        internal: true,
      );
    }
  }

  /// A client event (`client-*`, Echo's `whisper`): to the channel's other
  /// connections. As Pusher Channels requires, only on private and
  /// presence channels this connection has joined.
  Future<void> _whisper(String event, Map<String, Object?> payload) async {
    final channel = payload['channel'];
    // Not on encrypted channels: the server cannot read them, so Pusher
    // does not relay their client events either.
    if (channel is! String ||
        !_subscriptions.containsKey(channel) ||
        channel.startsWith('private-encrypted-') ||
        !(channel.startsWith('private-') || channel.startsWith('presence-'))) {
      return;
    }
    await _server._send(channel, {
      'event': event,
      'channel': channel,
      'data': payload['data'],
    }, id);
  }

  Future<void> close() async {
    for (final channel in [..._subscriptions.keys]) {
      await _unsubscribe(channel);
    }
  }
}
