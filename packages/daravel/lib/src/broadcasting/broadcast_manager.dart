import 'dart:async';
import 'dart:convert';

import '../auth/auth_manager.dart';
import '../auth/contracts.dart';
import '../http/client.dart';
import '../http/http_exceptions.dart';
import '../http/request.dart';
import '../http/response.dart';
import '../logging/logger.dart';
import 'broadcast_config.dart';
import 'channel_registry.dart';
import 'pusher_server.dart';
import 'pusher_signature.dart';

/// An event that is broadcast when it is dispatched (Laravel's
/// `ShouldBroadcast`): `Event.dispatch(OrderShipped(order))` also sends it
/// to [broadcastOn]'s channels.
///
/// ```dart
/// final class OrderShipped with ShouldBroadcast {
///   OrderShipped(this.order);
///   final Order order;
///
///   @override
///   List<String> broadcastOn() => ['private-orders.${order.id}'];
///
///   @override
///   Map<String, Object?> broadcastWith() => {'id': order.id, 'status': 'shipped'};
/// }
/// ```
///
/// Channel names carry Pusher's prefixes, as Laravel's `PrivateChannel`
/// and `PresenceChannel` write them: `private-orders.7`, `presence-chat.1`.
abstract mixin class ShouldBroadcast {
  /// The channels to send to.
  List<String> broadcastOn();

  /// The event name clients listen for: `App\Events\<Class>` by default,
  /// what Laravel Echo's `.listen('OrderShipped')` expects.
  String broadcastAs() => 'App\\Events\\$runtimeType';

  /// The data sent (Laravel sends the public properties by default; Dart
  /// has no reflection, so say what to send).
  Map<String, Object?> broadcastWith() => const {};

  /// Whether to broadcast at all (Laravel's `broadcastWhen`).
  bool broadcastWhen() => true;

  /// The connection to leave out (`toOthers`).
  String? broadcastSocket;

  /// Not to the browser tab that made the current request: Laravel's
  /// `broadcast($event)->toOthers()`, using Echo's `X-Socket-ID` header.
  ShouldBroadcast toOthers() {
    broadcastSocket = AuthScope.request()?.header('x-socket-id');
    return this;
  }
}

/// Sends broadcast events where `BROADCAST_CONNECTION` says: this server
/// ([PusherServer]), another Reverb or Pusher Channels (their HTTP API),
/// the log, or nowhere.
final class BroadcastManager {
  BroadcastManager(this.config, {this.server, this._http, this._logger});

  final BroadcastConfig config;

  /// This server's Pusher endpoint, when it serves one (REVERB_APP_KEY and
  /// REVERB_APP_SECRET are set).
  final PusherServer? server;
  final HttpClientFactory? _http;
  final Logger? _logger;

  /// Sends [event] with [data] to [channels]; [exceptSocket] leaves that
  /// connection out.
  Future<void> send(
    String event,
    List<String> channels,
    Object? data, {
    String? exceptSocket,
  }) async {
    if (channels.isEmpty) {
      return;
    }
    switch (config.connection) {
      case 'daravel':
        final server = this.server;
        if (server == null) {
          throw StateError(
            'BROADCAST_CONNECTION=daravel needs this server to broadcast: '
            'call withBroadcasting() and set REVERB_APP_ID, REVERB_APP_KEY '
            'and REVERB_APP_SECRET.',
          );
        }
        await server.publish(event, channels, data, exceptSocket: exceptSocket);
      case 'reverb' || 'pusher':
        await _post(event, channels, data, exceptSocket);
      case 'log':
        _logger?.info('Broadcasting [$event] on [${channels.join(', ')}]', {
          'data': data,
        });
      case 'null':
        break;
      default:
        throw StateError(
          'BROADCAST_CONNECTION=${config.connection} is not a broadcast '
          'connection (daravel, reverb, pusher, log, null).',
        );
    }
  }

  /// Sends a [ShouldBroadcast] event, unless its `broadcastWhen` is false.
  Future<void> broadcast(ShouldBroadcast event) async {
    if (!event.broadcastWhen()) {
      return;
    }
    await send(
      event.broadcastAs(),
      event.broadcastOn(),
      event.broadcastWith(),
      exceptSocket: event.broadcastSocket,
    );
  }

  /// To another Reverb or Pusher Channels, as `pusher-php-server` does:
  /// `POST /apps/{id}/events`, signed with the app secret, in batches of
  /// 100 channels.
  Future<void> _post(
    String event,
    List<String> channels,
    Object? data,
    String? exceptSocket,
  ) async {
    final http = _http;
    final host = config.host;
    if (http == null || host == null) {
      throw StateError(
        'BROADCAST_CONNECTION=${config.connection} needs a host '
        '(${config.connection == 'pusher' ? 'PUSHER_HOST or PUSHER_APP_CLUSTER' : 'REVERB_HOST'}).',
      );
    }
    final path = '/apps/${config.appId}/events';
    for (var i = 0; i < channels.length; i += 100) {
      final body = jsonEncode({
        'name': event,
        'data': data is String ? data : jsonEncode(data),
        'channels': channels.sublist(i, (i + 100).clamp(0, channels.length)),
        'socket_id': ?exceptSocket,
      });
      final query = PusherSignature.signRequest(
        key: config.appKey,
        secret: config.appSecret,
        method: 'POST',
        path: path,
        body: body,
      );
      final url = Uri(
        scheme: config.scheme,
        host: host,
        port: config.port,
        path: path,
        queryParameters: query,
      );
      final response = await http
          .request()
          .withHeaders(const {'content-type': 'application/json'})
          .timeout(const Duration(seconds: 30))
          .post(url.toString(), body: body);
      if (!response.successful) {
        throw StateError(
          'Broadcasting to $host failed: ${response.status} ${response.body}',
        );
      }
    }
  }
}

/// Laravel's `/broadcasting/auth`: Echo asks before joining a private or
/// presence channel, and gets the signature the server checks.
final class BroadcastAuthorization {
  BroadcastAuthorization(this.config, this.channels, this._auth);

  final BroadcastConfig config;
  final ChannelRegistry channels;
  final AuthManager _auth;

  Future<Response> handle(Request request) async {
    final input = await request.all();
    final socketId = '${input['socket_id'] ?? ''}';
    final channel = '${input['channel_name'] ?? ''}';
    if (!RegExp(r'^\d+\.\d+$').hasMatch(socketId) || channel.isEmpty) {
      throw const HttpException(403, '');
    }
    final user = await _auth.user<Authenticatable>();
    final guarded =
        channel.startsWith('private-') || channel.startsWith('presence-');
    if (guarded && user == null) {
      throw const HttpException(403, '');
    }
    final result = user == null
        ? null
        : await channels.authorize(user, channel);
    if (result == null) {
      throw const HttpException(403, '');
    }
    if (!channel.startsWith('presence-')) {
      return Response.json(
        PusherSignature.authorizeChannel(
          key: config.appKey,
          secret: config.appSecret,
          socketId: socketId,
          channel: channel,
        ),
      );
    }
    // As pusher-php-server: the user id as a string, user_info when given.
    final channelData = jsonEncode({
      'user_id': '${user!.authIdentifier}',
      if (result is! bool) 'user_info': result,
    });
    return Response.json(
      PusherSignature.authorizeChannel(
        key: config.appKey,
        secret: config.appSecret,
        socketId: socketId,
        channel: channel,
        channelData: channelData,
      ),
    );
  }
}
