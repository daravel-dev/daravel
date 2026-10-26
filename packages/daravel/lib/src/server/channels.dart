import 'coordinator.dart';

/// Who is subscribed to which channel, across every worker isolate: the
/// coordinator side of the Pusher server (`broadcasting/pusher_server.dart`).
///
/// A presence channel's members are users: a user with two tabs open is
/// one member, added with the first connection and removed with the last,
/// as Laravel Reverb counts them.
final class ChannelMembershipService implements CoordinatorService {
  /// channel → socket id → (user id, user info); the user is null on
  /// channels that are not presence channels.
  final Map<String, Map<String, (String?, Object?)>> _channels = {};

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
    }
    throw CoordinatorException('Unknown channels operation [$op].');
  }

  Map<String, Object?> _join(
    String channel,
    String socket,
    String? userId,
    Object? userInfo,
  ) {
    final sockets = _channels.putIfAbsent(channel, () => {});
    final wasMember = userId != null && _users(channel).containsKey(userId);
    sockets[socket] = (userId, userInfo);
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
    for (final (userId, info) in (_channels[channel] ?? const {}).values)
      ?userId: info,
  };

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
