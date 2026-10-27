import 'dart:async';
import 'dart:convert';

import 'package:daravel/daravel.dart';

import 'client.dart';

/// Channel state shared by every broadcasting server through Redis
/// (`REVERB_SCALING_DRIVER=redis`), with the same results as the
/// database's: presence members, `member_added` once per user across the
/// servers, the channels API and cache channels.
///
/// A channel's connections are a hash (socket → server, user, join order);
/// each server keeps a heartbeat key alive ([beat]), and the connections of
/// a server whose key expired (it crashed) are dropped as they are read.
final class RedisChannelState implements ChannelState {
  RedisChannelState(this.client, {required this.server, this.prefix = ''});

  final RedisClient client;
  final String server;
  final String prefix;

  /// How long a server may stay silent before its members stop counting.
  static const Duration liveness = Duration(seconds: 30);

  /// How long a cache channel keeps its last frame, as Pusher Channels.
  static const Duration cacheTtl = Duration(minutes: 30);

  String get _base => '${prefix}daravel:broadcast:';
  String _members(String channel) => '${_base}members:$channel';
  String get _channels => '${_base}channels';
  String get _sequence => '${_base}seq';
  String _server(String name) => '${_base}server:$name';
  String _cache(String channel) => '${_base}cache:$channel';

  /// Says this server is alive.
  Future<void> beat() => client.set(_server(server), '1', ttl: liveness);

  /// The live connections of [channel], in join order; drops those of
  /// servers that stopped beating.
  Future<List<_Member>> _live(String channel) async {
    final reply = (await client.command(['HGETALL', _members(channel)]))!;
    final fields = reply is Map
        ? [
            for (final e in reply.entries) ...[e.key, e.value],
          ]
        : reply as List;
    final members = <_Member>[
      for (var i = 0; i + 1 < fields.length; i += 2)
        _Member.decode('${fields[i]}', '${fields[i + 1]}'),
    ];
    final servers = {for (final m in members) m.server}..remove(server);
    if (servers.isEmpty) {
      return members..sort((a, b) => a.order.compareTo(b.order));
    }
    final names = servers.toList();
    final alive =
        (await client.command(['MGET', ...names.map(_server)]))! as List;
    final dead = {
      for (var i = 0; i < names.length; i++)
        if (alive[i] == null) names[i],
    };
    final gone = [
      for (final m in members)
        if (dead.contains(m.server)) m.socket,
    ];
    if (gone.isNotEmpty) {
      await client.command(['HDEL', _members(channel), ...gone]);
    }
    return members.where((m) => !dead.contains(m.server)).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
  }

  static Map<String, Object?> _users(List<_Member> members) => {
    for (final m in members)
      if (m.userId != null) m.userId!: m.userInfo,
  };

  @override
  Future<Object?> call(String op, Map<String, Object?> args) async {
    switch (op) {
      case 'join':
        final channel = args['channel']! as String;
        final userId = args['user_id'] as String?;
        final order = (await client.command(['INCR', _sequence]))! as int;
        await (
          client.command([
            'HSET',
            _members(channel),
            args['socket']! as String,
            jsonEncode({
              's': server,
              'u': userId,
              'i': args['user_info'],
              'n': order,
            }),
          ]),
          client.command(['SADD', _channels, channel]),
        ).wait;
        if (userId == null) {
          return {'added': false, 'members': null};
        }
        final members = await _live(channel);
        return {
          // The user's first connection on any server.
          'added': members.where((m) => m.userId == userId).length == 1,
          'members': _users(members),
        };
      case 'leave':
        final channel = args['channel']! as String;
        final socket = args['socket']! as String;
        final raw = await client.command(['HGET', _members(channel), socket]);
        if (raw is! String) {
          return {'removed': null};
        }
        await client.command(['HDEL', _members(channel), socket]);
        final left = _Member.decode(socket, raw);
        final members = await _live(channel);
        if (members.isEmpty) {
          await client.command(['SREM', _channels, channel]);
        }
        final userId = left.userId;
        return {
          // The user's last connection on any server.
          'removed': userId != null && !members.any((m) => m.userId == userId)
              ? userId
              : null,
        };
      case 'channel':
        final members = await _live(args['channel']! as String);
        return {
          'occupied': members.isNotEmpty,
          'subscription_count': members.length,
          'user_count': _users(members).length,
        };
      case 'channels':
        final prefix = args['prefix'] as String? ?? '';
        final names = ((await client.command(['SMEMBERS', _channels]))! as List)
            .cast<String>();
        final counts = <String, int>{};
        for (final name in names.where((n) => n.startsWith(prefix))) {
          final members = await _live(name);
          if (members.isEmpty) {
            await client.command(['SREM', _channels, name]);
          } else {
            counts[name] = members.length;
          }
        }
        return counts;
      case 'users':
        return _users(await _live(args['channel']! as String)).keys.toList();
      case 'connections':
        final names = ((await client.command(['SMEMBERS', _channels]))! as List)
            .cast<String>();
        return {
          for (final name in names) ...(await _live(name)).map((m) => m.socket),
        }.length;
      case 'cache_set':
        await client.set(
          _cache(args['channel']! as String),
          args['frame']! as String,
          ttl: cacheTtl,
        );
        return null;
      case 'cache_get':
        return client.get(_cache(args['channel']! as String));
    }
    throw StateError('Unknown channels operation [$op].');
  }
}

final class _Member {
  _Member(this.socket, this.server, this.userId, this.userInfo, this.order);

  factory _Member.decode(String socket, String raw) {
    final data = jsonDecode(raw) as Map<String, Object?>;
    return _Member(
      socket,
      '${data['s']}',
      data['u'] as String?,
      data['i'],
      (data['n'] as num?)?.toInt() ?? 0,
    );
  }

  final String socket;
  final String server;
  final String? userId;
  final Object? userInfo;
  final int order;
}

/// Relays the Pusher server's frames between servers through Redis Pub/Sub
/// (`REVERB_SCALING_DRIVER=redis`), as Laravel Reverb does: each frame is
/// published once with the server that sent it, and every other server
/// hands it to its own connections. At most once, as Pub/Sub is.
final class RedisBroadcastRelay implements BroadcastRelay {
  RedisBroadcastRelay(this.client, {required this.state, this.prefix = ''});

  final RedisClient client;

  /// Sends the heartbeat while the relay runs.
  final RedisChannelState state;
  final String prefix;

  String get _topic => '${prefix}daravel:broadcast';
  RedisSubscription? _subscription;
  Timer? _heartbeat;

  @override
  Future<void> send(String channel, String envelope) => client.publish(
    _topic,
    jsonEncode({'o': state.server, 'c': channel, 'f': envelope}),
  );

  @override
  Future<void> start(
    void Function(String channel, String envelope) deliver,
  ) async {
    if (_subscription != null) {
      return;
    }
    await state.beat();
    _heartbeat = Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(state.beat().catchError((Object _) {})),
    );
    final subscription = _subscription = client.subscribe([_topic]);
    subscription.messages.listen((message) {
      final Map<String, Object?> data;
      try {
        data = jsonDecode(message.payload) as Map<String, Object?>;
      } on FormatException {
        return;
      }
      if (data['o'] != state.server) {
        deliver('${data['c']}', '${data['f']}');
      }
    });
    await subscription.ready;
  }

  @override
  Future<void> close() async {
    _heartbeat?.cancel();
    await _subscription?.cancel();
    _subscription = null;
  }
}
