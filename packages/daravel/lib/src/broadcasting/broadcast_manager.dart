import 'dart:async';
import 'dart:convert';

import '../auth/auth_manager.dart';
import '../auth/contracts.dart';
import '../database/database_manager.dart';
import '../foundation/retryable_job.dart';
import '../http/client.dart';
import '../http/http_exceptions.dart';
import '../http/request.dart';
import '../http/response.dart';
import '../logging/logger.dart';
import 'broadcast_config.dart';
import 'channel_registry.dart';
import 'pusher_server.dart';
import 'pusher_signature.dart';
import 'secretbox.dart';
import '../server/coordinator.dart';

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
  /// A manager broadcasting with [config], through the built-in [server]
  /// when there is one.
  BroadcastManager(
    this.config, {
    this.server,
    this._http,
    this._logger,
    this.database,
    this.onShed,
  });

  /// Told of each broadcast dropped because the coordinator could not
  /// take it (the application counts it and dispatches [BroadcastShed]).
  final void Function(BroadcastShed shed)? onShed;

  int _shedSinceWarning = 0;
  DateTime? _lastShedWarning;

  /// The database whose transactions broadcasts wait for
  /// ([BroadcastConfig.afterCommit]); none waits without it.
  final DatabaseManager? database;

  /// The broadcasting settings.
  final BroadcastConfig config;

  /// This server's Pusher endpoint, when it serves one (REVERB_APP_KEY and
  /// REVERB_APP_SECRET are set).
  final PusherServer? server;
  final HttpClientFactory? _http;
  final Logger? _logger;

  BroadcastFake? _fake;

  /// Records broadcasts instead of sending them (`Broadcast.fake()`), with
  /// the transaction rules kept: one made in a transaction that rolls back
  /// is not recorded, as it would not be sent.
  BroadcastFake fake() => _fake = BroadcastFake();

  /// Undoes [fake].
  void restore() => _fake = null;

  /// The fake recording now, if any.
  BroadcastFake? get faked => _fake;

  /// Sends [event] with [data] to [channels]; [exceptSocket] leaves that
  /// connection out.
  ///
  /// Inside a database transaction it is sent once the transaction commits,
  /// and dropped when it rolls back, unless [afterCommit] (default
  /// [BroadcastConfig.afterCommit], `BROADCAST_AFTER_COMMIT`) is false.
  Future<void> send(
    String event,
    List<String> channels,
    Object? data, {
    String? exceptSocket,
    bool? afterCommit,
  }) => _send(
    event,
    channels,
    data,
    exceptSocket: exceptSocket,
    afterCommit: afterCommit,
  );

  Future<void> _send(
    String event,
    List<String> channels,
    Object? data, {
    String? exceptSocket,
    bool? afterCommit,
    ShouldBroadcast? source,
  }) async {
    if (channels.isEmpty) {
      return;
    }
    final db = database;
    if ((afterCommit ?? config.afterCommit) && db != null && db.inTransaction) {
      await db.afterCommit(
        () => _sendNow(event, channels, data, exceptSocket, source),
      );
      return;
    }
    await _sendNow(event, channels, data, exceptSocket, source);
  }

  Future<void> _sendNow(
    String event,
    List<String> channels,
    Object? data,
    String? exceptSocket, [
    ShouldBroadcast? source,
  ]) async {
    if (_fake case final fake?) {
      fake.broadcasts.add(
        BroadcastRecord(
          event: event,
          channels: List.unmodifiable(channels),
          data: data,
          exceptSocket: exceptSocket,
          source: source,
        ),
      );
      return;
    }
    // Each end-to-end encrypted channel has its own key, so its own
    // payload (pusher-php-server refuses to mix them).
    final encrypted = [
      for (final channel in channels)
        if (channel.startsWith('private-encrypted-')) channel,
    ];
    if (encrypted.isNotEmpty) {
      final key = config.encryptionMasterKey;
      if (key == null) {
        throw StateError(
          'Broadcasting to ${encrypted.first} needs an encryption master '
          'key (REVERB_ENCRYPTION_MASTER_KEY_BASE64).',
        );
      }
      final text = data is String ? data : jsonEncode(data);
      for (final channel in encrypted) {
        await _deliver(
          event,
          [channel],
          PusherEncryption.encrypt(channel, text, key),
          exceptSocket,
        );
      }
      channels = [
        for (final channel in channels)
          if (!channel.startsWith('private-encrypted-')) channel,
      ];
      if (channels.isEmpty) {
        return;
      }
    }
    await _deliver(event, channels, data, exceptSocket);
  }

  Future<void> _deliver(
    String event,
    List<String> channels,
    Object? data,
    String? exceptSocket,
  ) async {
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
        try {
          await server.publish(
            event,
            channels,
            data,
            exceptSocket: exceptSocket,
          );
        } on CoordinatorException catch (error, stackTrace) {
          _shedOrRethrow(event, channels, error, stackTrace);
        }
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

  /// A broadcast through this server is best effort: when the coordinator
  /// cannot take it (it sheds bulk calls, [CoordinatorOverloaded], or does
  /// not answer in time, [CoordinatorTimeoutException]), it never fails
  /// the request that sent it, and is not lost in silence either: it is
  /// logged (a `warning` at most once a second, with the count),
  /// counted (`broadcast_shed_total`) and told ([onShed], the application's
  /// [BroadcastShed] event), and the request goes on. Inside a job whose
  /// failure is retried it is rethrown instead, so the job is retried by
  /// its `tries` and `backoff`: an application that must not lose an event
  /// sends it from a queued job. A `sync` job runs inline in its caller and
  /// cannot be retried, so there it is dropped and told as in a request. Any other error (a bad channel, a programming error) is
  /// rethrown everywhere. The other connections (`reverb`, `pusher`,
  /// `log`, `null`) are unchanged.
  void _shedOrRethrow(
    String event,
    List<String> channels,
    CoordinatorException error,
    StackTrace stackTrace,
  ) {
    final reason = switch (error) {
      CoordinatorTimeoutException() => 'timeout',
      CoordinatorOverloaded() => 'overloaded',
      _ => null,
    };
    if (reason == null || inRetryableJob) {
      // Rethrown with the stack of the call that failed, not this one.
      Error.throwWithStackTrace(error, stackTrace);
    }
    _shedSinceWarning++;
    final now = DateTime.now();
    final last = _lastShedWarning;
    if (last == null || now.difference(last) >= const Duration(seconds: 1)) {
      _logger?.warning(
        'Broadcast [$event] dropped: the coordinator could not take it '
        '($reason); $_shedSinceWarning dropped since the last warning.',
      );
      _lastShedWarning = now;
      _shedSinceWarning = 0;
    }
    onShed?.call(
      BroadcastShed(
        event: event,
        channels: List.unmodifiable(channels),
        reason: reason,
      ),
    );
  }

  /// Sends a [ShouldBroadcast] event, unless its `broadcastWhen` is false.
  Future<void> broadcast(ShouldBroadcast event) async {
    if (!event.broadcastWhen()) {
      return;
    }
    await _send(
      event.broadcastAs(),
      event.broadcastOn(),
      event.broadcastWith(),
      exceptSocket: event.broadcastSocket,
      source: event,
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
  /// Authorizes private and presence channel subscriptions with the
  /// channel callbacks of [channels].
  BroadcastAuthorization(this.config, this.channels, this._auth);

  /// The broadcasting settings.
  final BroadcastConfig config;

  /// The channel authorization callbacks (`routes/channels.dart`).
  final ChannelRegistry channels;
  final AuthManager _auth;

  /// Answers `POST /broadcasting/auth` with a signed authorization, or 403.
  Future<Response> handle(Request request) async {
    final input = await request.all();
    final socketId = '${input['socket_id'] ?? ''}';
    final channel = '${input['channel_name'] ?? ''}';
    // A name the Pusher protocol does not allow (more than 164 characters,
    // or others than `A-Z a-z 0-9 _ - = @ , . ;`) is refused before it
    // reaches the channel patterns: no client subscribes with one, and the
    // patterns' matching time grows with the name's length. 403, as
    // Laravel answers every refusal on this route.
    if (!RegExp(r'^\d+\.\d+$').hasMatch(socketId) ||
        !PusherServer.isValidChannelName(channel)) {
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
      final signed = PusherSignature.authorizeChannel(
        key: config.appKey,
        secret: config.appSecret,
        socketId: socketId,
        channel: channel,
      );
      if (!channel.startsWith('private-encrypted-')) {
        return Response.json(signed);
      }
      // The browser decrypts with the channel's key (pusher-php-server).
      final key = config.encryptionMasterKey;
      if (key == null) {
        throw StateError(
          '$channel needs an encryption master key '
          '(REVERB_ENCRYPTION_MASTER_KEY_BASE64).',
        );
      }
      return Response.json({
        ...signed,
        'shared_secret': base64.encode(
          PusherEncryption.sharedSecret(channel, key),
        ),
      });
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

/// Channel names with their Pusher prefix, for `broadcastOn` and
/// `Broadcast.send`: Laravel's `new PrivateChannel('orders.1')`,
/// `PresenceChannel` and `EncryptedPrivateChannel`.
///
/// ```dart
/// List<String> broadcastOn() => [Channels.private('orders.${order.id}')];
/// ```
abstract final class Channels {
  /// `private-<name>`.
  static String private(String name) => 'private-$name';

  /// `presence-<name>`.
  static String presence(String name) => 'presence-$name';

  /// `private-encrypted-<name>`.
  static String encrypted(String name) => 'private-encrypted-$name';
}

/// One broadcast `Broadcast.fake()` recorded.
final class BroadcastRecord {
  /// [event] with [data] to [channels], leaving out [exceptSocket]; [source]
  /// is the [ShouldBroadcast] it came from, when it did.
  const BroadcastRecord({
    required this.event,
    required this.channels,
    required this.data,
    this.exceptSocket,
    this.source,
  });

  /// The event name (`broadcastAs`).
  final String event;

  /// The channels, with their prefixes.
  final List<String> channels;

  /// The payload.
  final Object? data;

  /// The connection left out (`toOthers()`).
  final String? exceptSocket;

  /// The event object, for `Broadcast.event(...)` and `ShouldBroadcast`
  /// events; null for `Broadcast.send(...)`.
  final ShouldBroadcast? source;
}

/// What `Broadcast.fake()` recorded, with assertions in the manner of
/// `Mail.fake()` and `Queue.fake()`.
final class BroadcastFake {
  /// The broadcasts, in order.
  final List<BroadcastRecord> broadcasts = [];

  /// The events of type [E] broadcast (on [channel], matching [where]).
  List<E> broadcasted<E extends ShouldBroadcast>({
    String? channel,
    bool Function(E event)? where,
  }) => [
    for (final record in broadcasts)
      if (record.source case final E event
          when (channel == null || record.channels.contains(channel)) &&
              (where == null || where(event)))
        event,
  ];

  /// The broadcasts named [event] (`Broadcast.send` or `broadcastAs`), on
  /// [channel] when given.
  List<BroadcastRecord> named(String event, {String? channel}) => [
    for (final record in broadcasts)
      if (record.event == event &&
          (channel == null || record.channels.contains(channel)))
        record,
  ];

  /// Fails unless an event of type [E] (on [channel], matching [where]) was
  /// broadcast.
  void assertBroadcasted<E extends ShouldBroadcast>({
    String? channel,
    bool Function(E event)? where,
  }) {
    if (broadcasted<E>(channel: channel, where: where).isEmpty) {
      throw StateError(
        'Expected [$E] to be broadcast'
        '${channel == null ? '' : ' on [$channel]'}; it was not.',
      );
    }
  }

  /// Fails unless an event of type [E] (on [channel]) was broadcast [times]
  /// times.
  void assertBroadcastedTimes<E extends ShouldBroadcast>(
    int times, {
    String? channel,
  }) {
    final count = broadcasted<E>(channel: channel).length;
    if (count != times) {
      throw StateError(
        'Expected [$E] broadcast $times time(s); it was $count.',
      );
    }
  }

  /// Fails unless something named [event] was sent (on [channel]), for
  /// `Broadcast.send(...)`.
  void assertSent(String event, {String? channel}) {
    if (named(event, channel: channel).isEmpty) {
      throw StateError(
        'Expected [$event] to be broadcast'
        '${channel == null ? '' : ' on [$channel]'}; it was not.',
      );
    }
  }

  /// Fails if an event of type [E] (on [channel], matching [where]) was
  /// broadcast.
  void assertNotBroadcasted<E extends ShouldBroadcast>({
    String? channel,
    bool Function(E event)? where,
  }) {
    if (broadcasted<E>(channel: channel, where: where).isNotEmpty) {
      throw StateError('Expected [$E] not to be broadcast; it was.');
    }
  }

  /// Fails if anything was broadcast on [channel].
  void assertNothingBroadcastedTo(String channel) {
    final on = [
      for (final record in broadcasts)
        if (record.channels.contains(channel)) record.event,
    ];
    if (on.isNotEmpty) {
      throw StateError(
        'Expected nothing broadcast on [$channel]; got ${on.join(', ')}.',
      );
    }
  }

  /// Fails if anything was broadcast.
  void assertNothingBroadcasted() {
    if (broadcasts.isNotEmpty) {
      throw StateError(
        'Expected no broadcasts; got '
        '${[for (final r in broadcasts) r.event].join(', ')}.',
      );
    }
  }
}

/// A broadcast dropped because the coordinator could not take it
/// ([BroadcastManager]'s best effort): dispatched as an application event,
/// for instance to tell the clients of [channels] to reload.
///
/// A shed broadcast means "back off or drop": a listener (or a caller of
/// `Broadcaster.publish` catching `CoordinatorOverloaded`) must not publish
/// again at once in a loop. The refusal arrives on the next turn of the
/// event loop, not synchronously.
final class BroadcastShed {
  /// [event] on [channels], dropped for [reason] (`overloaded`, `timeout`).
  const BroadcastShed({
    required this.event,
    required this.channels,
    required this.reason,
  });

  /// The event's name.
  final String event;

  /// Where it was going.
  final List<String> channels;

  /// `overloaded` or `timeout`.
  final String reason;
}
