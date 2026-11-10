import 'dart:convert';

import '../foundation/clock.dart';
import 'broadcast.dart';
import 'coordinator.dart';

/// Who is subscribed to which channel, across every worker isolate: the
/// coordinator side of the Pusher server (`broadcasting/pusher_server.dart`).
///
/// A presence channel's members are users: a user with two tabs open is
/// one member, added with the first connection and removed with the last,
/// as Laravel Reverb counts them.
final class ChannelMembershipService
    with PrioritizedService
    implements CoordinatorService, WorkerAwareService {
  /// Normal: put off only while the coordinator is saturated.
  @override
  CoordinatorPriority get priority => CoordinatorPriority.normal;

  /// The membership of every channel; with [broadcast], the members a
  /// crashed worker held are announced as removed ([forgetWorker]).
  ChannelMembershipService({this.broadcast});

  /// Where [forgetWorker] publishes `pusher_internal:member_removed` for
  /// the users whose every connection was on the worker that is gone (the
  /// coordinator's `broadcast` service). Without it they vanish silently.
  final BroadcastService? broadcast;

  /// channel → socket id → (user id, user info, worker); the user is null
  /// on channels that are not presence channels, the worker is the isolate
  /// that holds the socket (`join`'s `worker`), so a crashed worker's
  /// sockets can be forgotten.
  final Map<String, Map<String, (String?, Object?, String?)>> _channels = {};

  /// channel → user id → (connections, user info), in join order: a
  /// presence channel's members, kept as sockets come and go, so a join or
  /// a leave no longer rebuilds them from every socket of the channel.
  final Map<String, Map<String, (int, Object?)>> _presence = {};

  /// socket id → channels it is on: `connections` without walking every
  /// channel.
  final Map<String, int> _sockets = {};

  /// Connections counted by `open` (only with a connection quota): socket
  /// id → the worker holding it.
  final Map<String, String?> _open = {};

  /// The last frame of each cache channel (`cache-…`, `private-cache-…`,
  /// `presence-cache-…`) and when it was sent: new subscribers get it.
  final Map<String, (String, DateTime)> _cached = {};

  /// How long a cache channel keeps its last frame, as Pusher Channels
  /// (Reverb forgets it when the channel empties).
  static const Duration cacheTtl = Duration(minutes: 30);

  /// The most cache channels whose last frame is kept. A frame was kept
  /// until its channel was read again, so one cache channel per user or
  /// document grew the map without bound; past this many the expired
  /// frames go, then the least recently written.
  static const int maxCachedFrames = 10000;

  /// Cache channels holding a frame right now.
  int get cachedFrames => _cached.length;

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
        return _sockets.length;
      case 'open':
        // A connection counted against the quota (`REVERB_APP_MAX_CONNECTIONS`).
        final max = (args['max'] as num?)?.toInt() ?? 0;
        if (max > 0 && _open.length >= max) {
          return false;
        }
        _open[args['socket']! as String] = args['worker'] as String?;
        return true;
      case 'close':
        _open.remove(args['socket']! as String);
        return null;
      case 'cache_set':
        final channel = args['channel']! as String;
        final now = Clock.now();
        _cached.remove(channel); // Most recently written last.
        if (_cached.length >= maxCachedFrames) {
          _cached.removeWhere(
            (_, cached) => now.difference(cached.$2) > cacheTtl,
          );
          while (_cached.length >= maxCachedFrames) {
            _cached.remove(_cached.keys.first);
          }
        }
        _cached[channel] = (args['frame']! as String, now);
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
    final previous = sockets[socket];
    sockets[socket] = (userId, userInfo, worker);
    if (previous == null) {
      _sockets[socket] = (_sockets[socket] ?? 0) + 1;
    }
    if (userId == null) {
      _release(channel, previous?.$1);
      return {'added': false, 'members': null};
    }
    final users = _presence.putIfAbsent(channel, () => {});
    final member = users[userId];
    if (previous != null && previous.$1 == userId) {
      // The same connection subscribing again: still one member.
      users[userId] = (member?.$1 ?? 1, userInfo);
      return {'added': false, 'members': _users(channel)};
    }
    _release(channel, previous?.$1);
    users[userId] = (
      (member?.$1 ?? 0) + 1,
      // The latest connection's info, at the user's first place.
      userInfo,
    );
    return {
      // The user's first connection: the others hear member_added.
      'added': member == null,
      'members': _users(channel),
    };
  }

  Map<String, Object?> _leave(String channel, String socket) {
    final sockets = _channels[channel];
    final left = sockets?.remove(socket);
    if (sockets != null && sockets.isEmpty) {
      _channels.remove(channel);
    }
    if (left == null) {
      return {'removed': null};
    }
    _forgetSocket(socket);
    final userId = left.$1;
    return {
      // The user's last connection: the others hear member_removed.
      'removed': _release(channel, userId) ? userId : null,
    };
  }

  /// One connection of [userId] fewer on [channel]; true when it was the
  /// user's last.
  bool _release(String channel, String? userId) {
    if (userId == null) {
      return false;
    }
    final users = _presence[channel];
    final member = users?[userId];
    if (users == null || member == null) {
      return false;
    }
    if (member.$1 > 1) {
      users[userId] = (member.$1 - 1, member.$2);
      return false;
    }
    users.remove(userId);
    if (users.isEmpty) {
      _presence.remove(channel);
    }
    return true;
  }

  void _forgetSocket(String socket) {
    final count = _sockets[socket];
    if (count == null || count <= 1) {
      _sockets.remove(socket);
    } else {
      _sockets[socket] = count - 1;
    }
  }

  /// user id → user info, in join order.
  Map<String, Object?> _users(String channel) => {
    for (final MapEntry(key: userId, value: (_, info))
        in (_presence[channel] ?? const {}).entries)
      userId: info,
  };

  /// Drops every socket [worker] held. A user whose last connection to a
  /// presence channel was among them leaves its members, and the channel's
  /// other subscribers get `pusher_internal:member_removed` through
  /// [broadcast], as if the worker had closed the connections itself (it
  /// is gone and cannot). Without [broadcast] they learn at the next member
  /// event or by reading the member list again.
  @override
  void forgetWorker(String worker) {
    _open.removeWhere((_, holder) => holder == worker);
    final removed = <(String, String)>[];
    for (final channel in _channels.keys.toList()) {
      final sockets = _channels[channel]!;
      for (final socket in sockets.keys.toList()) {
        final entry = sockets[socket]!;
        if (entry.$3 == worker) {
          sockets.remove(socket);
          _forgetSocket(socket);
          final userId = entry.$1;
          if (_release(channel, userId) && userId != null) {
            removed.add((channel, userId));
          }
        }
      }
      if (sockets.isEmpty) {
        _channels.remove(channel);
      }
    }
    final broadcast = this.broadcast;
    if (broadcast == null) {
      return;
    }
    for (final (channel, userId) in removed) {
      // `<except>\n<frame>` with no socket excepted, the frame the Pusher
      // server sends when a connection leaves.
      final frame = jsonEncode({
        'event': 'pusher_internal:member_removed',
        'data': jsonEncode({'user_id': userId}),
        'channel': channel,
      });
      broadcast.handle('publish', {'channel': channel, 'message': '\n$frame'});
    }
  }

  Map<String, Object?> _info(String channel) {
    final sockets = _channels[channel];
    return {
      'occupied': sockets != null,
      'subscription_count': sockets?.length ?? 0,
      'user_count': _presence[channel]?.length ?? 0,
    };
  }

  @override
  Map<String, Object?> stats() => <String, Object?>{
    'channels': _channels.length,
    'connections': _sockets.length,
    if (_open.isNotEmpty) 'open': _open.length,
  };
}
