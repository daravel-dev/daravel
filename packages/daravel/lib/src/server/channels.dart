import '../foundation/clock.dart';
import 'coordinator.dart';

/// Who is subscribed to which channel, across every worker isolate: the
/// coordinator side of the Pusher server (`broadcasting/pusher_server.dart`).
///
/// A presence channel's members are users: a user with two tabs open is
/// one member, added with the first connection and removed with the last,
/// as Laravel Reverb counts them.
final class ChannelMembershipService
    implements CoordinatorService, WorkerAwareService {
  /// channel → socket id → (user id, user info, worker); the user is null
  /// on channels that are not presence channels, the worker is the isolate
  /// that holds the socket (`join`'s `worker`), so a crashed worker's
  /// sockets can be forgotten.
  final Map<String, Map<String, (String?, Object?, String?)>> _channels = {};

  /// The last frame of each cache channel (`cache-…`, `private-cache-…`,
  /// `presence-cache-…`) and when it was sent: new subscribers get it.
  final Map<String, (String, DateTime)> _cached = {};

  /// How long a cache channel keeps its last frame, as Pusher Channels
  /// (Reverb forgets it when the channel empties).
  static const Duration cacheTtl = Duration(minutes: 30);

  @override
  String get name => 'channels';

  @override
  Object? handle(String op, Map<String, Object?> args) {
    switch (op) {
      case 'join':
        return _join(
          args['channel']! as String,
          args['socket']! as String,
          args['user_id'] as String?,
          args['user_info'],
          args['worker'] as String?,
        );
      case 'leave':
        return _leave(args['channel']! as String, args['socket']! as String);
      case 'channel':
        return _info(args['channel']! as String);
      case 'channels':
        final prefix = args['prefix'] as String? ?? '';
        return {
          for (final MapEntry(key: name, value: sockets) in _channels.entries)
            if (name.startsWith(prefix)) name: sockets.length,
        };
      case 'users':
        return _users(args['channel']! as String).keys.toList();
      case 'connections':
        return {for (final sockets in _channels.values) ...sockets.keys}.length;
      case 'cache_set':
        _cached[args['channel']! as String] = (
          args['frame']! as String,
          Clock.now(),
        );
        return null;
      case 'cache_get':
        final channel = args['channel']! as String;
        final cached = _cached[channel];
        if (cached == null) {
          return null;
        }
        if (Clock.now().difference(cached.$2) > cacheTtl) {
          _cached.remove(channel);
          return null;
        }
        return cached.$1;
    }
    throw CoordinatorException('Unknown channels operation [$op].');
  }

  Map<String, Object?> _join(
    String channel,
    String socket,
    String? userId,
    Object? userInfo,
    String? worker,
  ) {
    final sockets = _channels.putIfAbsent(channel, () => {});
    final wasMember = userId != null && _users(channel).containsKey(userId);
    sockets[socket] = (userId, userInfo, worker);
    return {
      // The user's first connection: the others hear member_added.
      'added': userId != null && !wasMember,
      'members': userId == null ? null : _users(channel),
    };
  }

  Map<String, Object?> _leave(String channel, String socket) {
    final sockets = _channels[channel];
    final left = sockets?.remove(socket);
    if (sockets != null && sockets.isEmpty) {
      _channels.remove(channel);
    }
    final userId = left?.$1;
    return {
      // The user's last connection: the others hear member_removed.
      'removed': userId != null && !_users(channel).containsKey(userId)
          ? userId
          : null,
    };
  }

  /// user id → user info, in join order.
  Map<String, Object?> _users(String channel) => {
    for (final (userId, info, _) in (_channels[channel] ?? const {}).values)
      ?userId: info,
  };

  /// Drops every socket [worker] held. The members it made vanish from
  /// `users` and `channel`; their `member_removed` is not sent (the worker
  /// that would have sent it is gone), so clients learn at the next member
  /// event or by reading the member list again.
  @override
  void forgetWorker(String worker) {
    for (final channel in _channels.keys.toList()) {
      final sockets = _channels[channel]!
        ..removeWhere((_, socket) => socket.$3 == worker);
      if (sockets.isEmpty) {
        _channels.remove(channel);
      }
    }
  }

  Map<String, Object?> _info(String channel) {
    final sockets = _channels[channel];
    return {
      'occupied': sockets != null,
      'subscription_count': sockets?.length ?? 0,
      'user_count': _users(channel).length,
    };
  }

  @override
  Map<String, Object?> stats() => <String, Object?>{
    'channels': _channels.length,
    'connections': handle('connections', const {}),
  };
}
