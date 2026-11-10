import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:meta/meta.dart';

import '../foundation/clock.dart';
import '../foundation/shared_result.dart';
import '../http/request.dart';
import '../http/response.dart';
import '../server/broadcast.dart';
import '../server/coordinator.dart';
import 'app_provider.dart';
import 'broadcast_config.dart';
import 'cluster.dart';
import 'pusher_observer.dart';
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
  /// A Pusher-protocol WebSocket server (Reverb's) inside the application.
  PusherServer(
    this.config,
    this._broadcaster,
    CoordinatorChannel coordinator, {
    ChannelState? state,
    this.relay,
    this.onError,
    this.onRejected,
    BroadcastAppProvider? apps,
    this.observer = const PusherObserver(),
  }) : _coordinator = coordinator,
       _state = state ?? _CoordinatorChannelState(coordinator),
       apps = apps ?? SingleAppProvider.fromConfig(config);

  final CoordinatorChannel _coordinator;

  /// Told about connections, subscriptions, messages, fan-out and
  /// refusals, per application (metrics, Pulse, the dashboard).
  final PusherObserver observer;

  /// The application id of [topic] ([topicOf]).
  String appOf(String topic) {
    final colon = topic.indexOf(':');
    return colon < 0 ? config.appId : topic.substring(0, colon);
  }

  void _rejected(String reason, BroadcastApp app) {
    onRejected?.call(reason);
    observer.rejected(app.id, reason);
  }

  /// The applications served (`withBroadcasting(apps:)`); by default the
  /// one of the `REVERB_APP_*` settings.
  final BroadcastAppProvider apps;

  /// Where [app]'s [channel] lives in the broadcaster, the coordinator and
  /// the relay: the channel itself for the settings' application
  /// (`REVERB_APP_ID`), so a single-app server and its state are as
  /// before, and `<app id>:<channel>` for any other, which no Pusher
  /// channel name can be (`:` is not allowed in one).
  String topicOf(BroadcastApp? app, String channel) =>
      app == null || app.id == config.appId ? channel : '${app.id}:$channel';

  /// The channel name a client sees for [topic] ([topicOf]).
  static String channelOf(String topic) {
    final colon = topic.indexOf(':');
    return colon < 0 ? topic : topic.substring(colon + 1);
  }

  /// Told about failures no client can be told about: a channel left on
  /// close whose `leave` failed twice, a relay that would not start.
  final void Function(String message, Object error)? onError;

  /// Told when a connection, message or subscription is refused, with why:
  /// `connection_quota` (4004), `rate_limit` (4301, `rate_limiting`),
  /// `client_event_rate` (4301, client events per second) or
  /// `channel_limit` (4300); the `reverb_rejected_total` metric.
  final void Function(String reason)? onRejected;

  /// The broadcasting settings.
  final BroadcastConfig config;
  final Broadcaster _broadcaster;
  final ChannelState _state;

  /// Carries frames to the other servers, and theirs to this one.
  final BroadcastRelay? relay;

  /// Starts reading the other servers' frames (once, at the first client).
  /// Shared by the connections that arrive meanwhile, each in a zone of
  /// its own: a [SharedResult], so a relay that fails to start reaches
  /// every one of them, not only the first. Cleared when the start fails,
  /// so a later client tries again.
  SharedResult<void>? _relaying;

  /// When the relay last failed to start (wall clock: a pause between
  /// tries, not domain time).
  DateTime? _relayFailedAt;

  /// After a failed relay start, clients are refused (4100) without a new
  /// try for this long, so a flood of connections does not hammer a Redis
  /// or a database that is down. One second; tests shorten it.
  @visibleForTesting
  Duration relayRetryPause = const Duration(seconds: 1);

  /// The relay start to wait on: the one in progress or done, a new one,
  /// or null while the pause after a failed start lasts.
  SharedResult<void>? _relayStart(BroadcastRelay relay) {
    final running = _relaying;
    if (running != null) {
      return running;
    }
    final failedAt = _relayFailedAt;
    if (failedAt != null &&
        DateTime.now().difference(failedAt) < relayRetryPause) {
      return null;
    }
    return _relaying = SharedResult(() async {
      try {
        await relay.start(_broadcaster.deliverLocally);
        _relayFailedAt = null;
      } on Object {
        // Not kept: a client after the pause starts it again.
        _relayFailedAt = DateTime.now();
        _relaying = null;
        rethrow;
      }
    });
  }

  /// Stops relaying (application shutdown).
  Future<void> close() async => relay?.close();

  /// The close code of a client too slow to read what it is sent (Pusher's
  /// 4100, "over capacity": reconnect after a backoff).
  static const int slowClientCode = 4100;

  static final Random _random = Random.secure();

  /// Publishes [event] with [data] (a string, sent as it is, or anything
  /// else as JSON) to [channels] of [app] (the settings' application by
  /// default), except to the connection [exceptSocket].
  Future<void> publish(
    String event,
    List<String> channels,
    Object? data, {
    String? exceptSocket,
    BroadcastApp? app,
  }) async {
    for (final channel in channels) {
      if (_scopedName(channel)) {
        throw ArgumentError.value(
          channel,
          'channels',
          'a channel name cannot contain ":"',
        );
      }
    }
    final text = data is String ? data : jsonEncode(data);
    // Channels at once: each is its own round trip, and only the order
    // within a channel matters.
    await Future.wait([
      for (final channel in channels)
        _send(topicOf(app, channel), {
          'event': event,
          'channel': channel,
          'data': text,
        }, exceptSocket),
    ]);
  }

  /// One frame, encoded once, to every connection on [topic] ([topicOf])
  /// but [except]: `<socket id>\n<frame>`. A cache channel also keeps it
  /// for the next subscribers, unless [internal] (member_added and
  /// _removed).
  Future<void> _send(
    String topic,
    Map<String, Object?> frame,
    String? except, {
    bool internal = false,
  }) async {
    final text = jsonEncode(frame);
    if (!internal && isCacheChannel(channelOf(topic))) {
      await _call('cache_set', {'channel': topic, 'frame': text});
    }
    final envelope = '${except ?? ''}\n$text';
    final watch = Stopwatch()..start();
    await _broadcaster.publish(topic, envelope);
    await relay?.send(topic, envelope);
    observer.published(appOf(topic), watch.elapsed);
  }

  /// Pusher's channel name rule: at most 164 characters of `A-Z a-z 0-9`
  /// and `_ - = @ , . ;` (prefixes included).
  static bool isValidChannelName(String channel) =>
      channel.length <= 164 && _channelName.hasMatch(channel);

  static final RegExp _channelName = RegExp(r'^[A-Za-z0-9_=@,.;-]+$');

  /// A name with `:`, which [topicOf] reserves for the channels of other
  /// applications: refused even when channel names are not validated, so
  /// no client reaches another application's channel.
  static bool _scopedName(String channel) => channel.contains(':');

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
    final app = await apps.byKey(appKey);
    if (app == null) {
      socket.add(_error(4001, 'Application does not exist'));
      await socket.close();
      return;
    }
    final id =
        '${_random.nextInt(1000000000) + 1}.${_random.nextInt(1000000000) + 1}';
    // Reverb checks the quota first, before the origin.
    if (app.maxConnections > 0) {
      if (!await _open(id, app)) {
        _rejected('connection_quota', app);
        socket.add(_error(4004, 'Application is over connection quota'));
        await socket.close();
        return;
      }
      try {
        await _serve(socket, request, id, app);
      } finally {
        await _close(id);
      }
      return;
    }
    await _serve(socket, request, id, app);
  }

  /// Counts connection [id] against [app]'s quota in the coordinator, every
  /// worker isolate together; true when it fits. A coordinator that fails
  /// lets the connection in (and is reported): a quota is a guard, not a
  /// reason to refuse every client.
  Future<bool> _open(String id, BroadcastApp app) async {
    try {
      return await _coordinator.call('channels', 'open', {
            'socket': id,
            'max': app.maxConnections,
            'app': app.id,
            'worker': Isolate.current.debugName,
          }) !=
          false;
    } on Object catch (error) {
      onError?.call('Connection quota could not be checked', error);
      return true;
    }
  }

  Future<void> _close(String id) async {
    try {
      await _coordinator.call('channels', 'close', {'socket': id});
    } on Object catch (error) {
      onError?.call('Connection $id could not leave the quota', error);
    }
  }

  Future<void> _serve(
    WebSocket socket,
    Request request,
    String id,
    BroadcastApp app,
  ) async {
    if (!_originAllowed(app, request.header('origin'))) {
      socket.add(_error(4009, 'Origin not allowed'));
      await socket.close();
      return;
    }
    final relay = this.relay;
    if (relay != null) {
      final relaying = _relayStart(relay);
      Object? failure;
      if (relaying == null) {
        failure = 'paused after a failed start';
      } else {
        try {
          await relaying.value;
        } on Object catch (error) {
          failure = error;
          onError?.call('Broadcast relay did not start', error);
        }
      }
      if (failure != null) {
        socket.add(_error(4100, 'Over capacity'));
        await socket.close(4100, 'Over capacity');
        return;
      }
    }
    final connection = _Connection(this, socket, id, app);
    observer.connectionOpened(app.id);
    socket.pingInterval = Duration(seconds: app.activityTimeout);
    connection.send(
      jsonEncode({
        'event': 'pusher:connection_established',
        'data': jsonEncode({
          'socket_id': connection.id,
          'activity_timeout': app.activityTimeout,
        }),
      }),
    );
    try {
      await for (final message in socket) {
        try {
          await connection.receive(message);
        } on Object catch (error) {
          // The coordinator (or the scaling store) failed: the client
          // reconnects, rather than staying with a read loop that is gone.
          // 4100 (back off) when it is overloaded, 4200 otherwise.
          final code = error is CoordinatorException ? 4100 : 4200;
          final reason = code == 4100
              ? 'Over capacity'
              : 'Generic reconnect immediately';
          connection._error(code, reason);
          await socket.close(code, reason);
          break;
        }
      }
    } on Object {
      // The connection dropped.
    } finally {
      try {
        await connection.close();
      } finally {
        observer.connectionClosed(app.id);
      }
    }
  }

  static bool _originAllowed(BroadcastApp app, String? origin) {
    if (app.allowedOrigins.contains('*')) {
      return true;
    }
    final host = origin == null ? null : Uri.tryParse(origin)?.host;
    if (host == null || host.isEmpty) {
      return false;
    }
    return app.allowedOrigins.any(
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

  /// The application [appId] names, when [request] is signed with its
  /// secret; otherwise the refusal to answer with.
  Future<(BroadcastApp?, Response?)> _verify(
    Request request,
    String appId,
  ) async {
    final app = await apps.byId(appId);
    if (app == null) {
      return (
        null,
        Response.json({
          'message': 'No matching application for ID [$appId].',
        }, status: 404),
      );
    }
    final body = utf8.decode(await request.bytes(), allowMalformed: true);
    if (!PusherSignature.verifyRequest(
      secret: app.secret,
      method: request.method,
      path: request.path,
      query: request.query,
      body: body,
    )) {
      return (
        null,
        Response.json({
          'message': 'Authentication signature invalid.',
        }, status: 401),
      );
    }
    return (app, null);
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
    final (app, refused) = await _verify(request, appId);
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
    if (channels.any(_scopedName)) {
      return _invalid('Channel names cannot contain ":".');
    }
    await publish(
      name,
      channels,
      data,
      exceptSocket: body?['socket_id'] as String?,
      app: app,
    );
    return Response.json(<String, Object?>{});
  }

  /// `POST /apps/{id}/batch_events`: `{"batch": [{"name", "data",
  /// "channel", "socket_id"?}, ...]}`.
  Future<Response> batchEvents(Request request, String appId) async {
    final (app, refused) = await _verify(request, appId);
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
              item['channel'] is! String ||
              _scopedName(item['channel']! as String),
        )) {
      return _invalid(
        'Each batch item needs name, data and a channel without ":".',
      );
    }
    for (final item in batch.cast<Map<String, Object?>>()) {
      await publish(
        item['name']! as String,
        [item['channel']! as String],
        item['data'],
        exceptSocket: item['socket_id'] as String?,
        app: app,
      );
    }
    return Response.json({'batch': <String, Object?>{}});
  }

  /// `GET /apps/{id}/channels?filter_by_prefix=&info=user_count`.
  Future<Response> channels(Request request, String appId) async {
    final (app, refused) = await _verify(request, appId);
    if (refused != null) {
      return refused;
    }
    final prefix = request.query['filter_by_prefix'] ?? '';
    final userCount = (request.query['info'] ?? '').contains('user_count');
    final scoped = topicOf(app, prefix);
    final counts =
        (await _call('channels', {'prefix': scoped}))! as Map<Object?, Object?>;
    final out = <String, Object?>{};
    for (final topic in counts.keys.cast<String>()) {
      // The settings' application owns the unscoped topics only.
      if (topicOf(app, channelOf(topic)) != topic) {
        continue;
      }
      final name = channelOf(topic);
      out[name] = userCount && name.startsWith('presence-')
          ? {
              'user_count':
                  ((await _call('channel', {'channel': topic}))!
                      as Map)['user_count'],
            }
          : <String, Object?>{};
    }
    return Response.json({'channels': out});
  }

  /// `GET /apps/{id}/channels/{channel}?info=user_count,subscription_count`.
  Future<Response> channel(Request request, String appId, String name) async {
    final (app, refused) = await _verify(request, appId);
    if (refused != null) {
      return refused;
    }
    if (_scopedName(name)) {
      return _invalid('Channel names cannot contain ":".');
    }
    final info =
        (await _call('channel', {'channel': topicOf(app, name)}))! as Map;
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
    final (app, refused) = await _verify(request, appId);
    if (refused != null) {
      return refused;
    }
    if (!name.startsWith('presence-') || _scopedName(name)) {
      return _invalid('Only presence channels have users.');
    }
    final ids =
        (await _call('users', {'channel': topicOf(app, name)}))! as List;
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
  _Connection(this._server, this._socket, this.id, this._app);

  final PusherServer _server;
  final WebSocket _socket;

  /// The application this client connected to (`/app/{key}`).
  final BroadcastApp _app;

  /// Where [channel] of this connection's application lives.
  String _topic(String channel) => _server.topicOf(_app, channel);

  /// The socket id (`123.456`): signed into channel authorizations and
  /// sent as `X-Socket-ID` for `toOthers()`.
  final String id;

  final Map<String, BroadcastSubscription> _subscriptions = {};

  /// Frames of a channel that arrived before its `subscription_succeeded`
  /// went out; sent after it, as Pusher clients expect.
  final Map<String, List<String>> _early = {};

  /// The members of each presence channel this connection was told about:
  /// its `subscription_succeeded` snapshot, then `member_added` and
  /// `member_removed`. Across servers a member event can arrive after the
  /// snapshot already holds its change; those are dropped, so a client
  /// never hears that a member it has joined.
  final Map<String, Set<String>> _members = {};

  void _deliver(String channel, String frame) {
    final early = _early[channel];
    if (early != null) {
      early.add(frame);
      return;
    }
    final members = _members[channel];
    if (members != null) {
      final message = _decodeMap(frame);
      final event = message['event'];
      if (event == 'pusher_internal:member_added' ||
          event == 'pusher_internal:member_removed') {
        final data = switch (message['data']) {
          final String text => _decodeMap(text),
          final Map<String, Object?> map => map,
          _ => const <String, Object?>{},
        };
        final userId = '${data['user_id']}';
        final fresh = event == 'pusher_internal:member_added'
            ? members.add(userId)
            : members.remove(userId);
        if (!fresh) {
          return;
        }
      }
    }
    send(frame);
  }

  void send(String text) {
    if (_socket.closeCode != null) {
      return;
    }
    try {
      _socket.add(text);
      _server.observer
        ..sent(_app.id)
        ..frame(_app.id, id, 'out', text);
    } on StateError {
      // Closed by this side and not done yet (dart:io keeps closeCode null
      // until the peer answers): nothing more goes out.
    }
  }

  void _error(int code, String message) =>
      send(PusherServer._error(code, message));

  Future<void> receive(Object? message) async {
    _server.observer
      ..received(_app.id)
      ..frame(_app.id, id, 'in', message);
    if (!_withinRateLimit()) {
      _server._rejected('rate_limit', _app);
      _error(4301, 'Rate limit exceeded');
      if (_app.rateLimiting?.terminate ?? false) {
        await _socket.close(4301, 'Rate limit exceeded');
      }
      return;
    }
    final max = _app.maxMessageSize;
    if (message is! String ||
        // A character is at most 3 bytes: measure only when it could matter.
        (message.length * 3 > max && utf8.encode(message).length > max)) {
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
        final config = _server.config;
        if (PusherServer._scopedName(channel) ||
            (config.validateChannelNames &&
                !PusherServer.isValidChannelName(channel))) {
          return _error(4300, 'Invalid channel name');
        }
        final most = config.maxChannelsPerConnection;
        if (most > 0 &&
            _subscriptions.length >= most &&
            !_subscriptions.containsKey(channel)) {
          _server._rejected('channel_limit', _app);
          return _error(
            4300,
            'Too many channels on this connection (at most $most)',
          );
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
        if (!_allowClientEvent()) {
          // Dropped, the connection kept, as Pusher does.
          _server._rejected('client_event_rate', _app);
          return _error(4301, 'Rate limit exceeded');
        }
        await _whisper(event, payload);
    }
  }

  /// Messages counted in the current rate limiting window, and when it
  /// ends ([BroadcastApp.rateLimiting]).
  int _messages = 0;
  DateTime? _windowEnds;

  /// Reverb's `ensureWithinRateLimit` (Laravel's `RateLimiter`): a window
  /// of the app's [BroadcastRateLimit.decay] opens with the first message,
  /// and past [BroadcastRateLimit.maxAttempts] messages in it the next are
  /// refused, without counting, until it ends.
  bool _withinRateLimit() {
    final limit = _app.rateLimiting;
    if (limit == null) {
      return true;
    }
    final now = Clock.now();
    final ends = _windowEnds;
    if (ends != null && !now.isBefore(ends)) {
      _messages = 0;
      _windowEnds = null;
    }
    if (_messages >= limit.maxAttempts) {
      return false;
    }
    _messages++;
    _windowEnds ??= now.add(limit.decay);
    return true;
  }

  /// Client events counted in the current second, and when it started.
  int _clientEvents = 0;
  DateTime? _clientEventsSince;

  /// Whether one more client event fits in this second
  /// ([BroadcastConfig.clientEventsPerSecond]).
  bool _allowClientEvent() {
    final limit = _server.config.clientEventsPerSecond;
    if (limit <= 0) {
      return true;
    }
    final now = Clock.now();
    final since = _clientEventsSince;
    if (since == null || now.difference(since) >= const Duration(seconds: 1)) {
      _clientEventsSince = now;
      _clientEvents = 0;
    }
    return ++_clientEvents <= limit;
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
          secret: _app.secret,
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
    final topic = _topic(channel);
    if (!_subscriptions.containsKey(channel)) {
      // Listening first, so nothing published from here on is missed;
      // what arrives before subscription_succeeded waits for it.
      _early[channel] = [];
      final subscription = await _server._broadcaster.subscribe(topic);
      subscription.messages.listen((envelope) {
        final newline = envelope.indexOf('\n');
        // `<except>\n<frame>`: not to the connection that sent it.
        if (envelope.substring(0, newline) != id) {
          _deliver(channel, envelope.substring(newline + 1));
        }
      });
      _subscriptions[channel] = subscription;
      _server.observer.subscribed(_app.id, channel);
    }
    final Map<Object?, Object?> joined;
    try {
      joined =
          (await _server._call('join', {
                'channel': topic,
                'socket': id,
                'user_id': userId,
                'user_info': userInfo,
                'worker': Isolate.current.debugName,
              }))!
              as Map;
    } on Object {
      _early.remove(channel); // nothing to wait for any more
      rethrow;
    }
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
    if (presence) {
      _members[channel] = {for (final key in members?.keys ?? const []) '$key'};
    }
    if (PusherServer.isCacheChannel(channel)) {
      final cached = await _server._call('cache_get', {'channel': topic});
      send(
        cached is String
            ? cached
            : jsonEncode({'event': 'pusher:cache_miss', 'channel': channel}),
      );
    }
    // Now the frames that arrived meanwhile, after the snapshot they follow.
    for (final frame in _early.remove(channel) ?? const <String>[]) {
      _deliver(channel, frame);
    }
    if (joined['added'] == true) {
      await _server._send(
        topic,
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
    _early.remove(channel);
    _members.remove(channel);
    if (subscription == null) {
      return;
    }
    await subscription.cancel();
    _server.observer.unsubscribed(_app.id, channel);
    await _leave(channel);
  }

  /// Leaves [channel] in the shared state, then tells the others when the
  /// user's last connection left.
  Future<void> _leave(String channel) async {
    final topic = _topic(channel);
    final left =
        (await _server._call('leave', {'channel': topic, 'socket': id}))!
            as Map;
    final removed = left['removed'];
    if (removed != null) {
      await _server._send(
        topic,
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
    await _server._send(_topic(channel), {
      'event': event,
      'channel': channel,
      'data': payload['data'],
    }, id);
  }

  /// Leaves every channel, each on its own: a `leave` that fails (the
  /// coordinator timed out) is tried once more and then reported, and
  /// never keeps the other channels subscribed.
  Future<void> close() async {
    for (final channel in [..._subscriptions.keys]) {
      try {
        await _unsubscribe(channel);
      } on Object {
        try {
          await _leave(channel);
        } on Object catch (error) {
          _server.onError?.call(
            'Connection $id could not leave $channel',
            error,
          );
        }
      }
    }
  }
}
