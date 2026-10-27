import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../database/database_manager.dart';
import '../database/query/query_builder.dart';
import '../database/schema/migration.dart';
import '../database/schema/schema_builder.dart';
import '../foundation/clock.dart';

/// Where a [PusherServer] keeps who is on which channel, the members of
/// presence channels and the last event of cache channels: the
/// coordinator (one server, every isolate) or the database
/// ([DatabaseChannelState], several servers). The operations and their
/// results are the coordinator's `ChannelMembershipService`'s.
abstract interface class ChannelState {
  Future<Object?> call(String op, Map<String, Object?> args);
}

/// This server's name among the others when [BroadcastConfig.serverId] is
/// not set: the host and the process, which every worker isolate shares.
String defaultBroadcastServerId() => '${Platform.localHostname}:$pid';

/// Channel state shared by every server through the database
/// (`REVERB_SCALING_ENABLED`): a presence channel's members are the same
/// whichever server a client is connected to, and `member_added` goes out
/// once per user across all of them.
///
/// Each server sends a heartbeat ([beat]); members of a server that has
/// been silent for [liveness] (it crashed) are no longer counted, and
/// [prune] deletes them.
final class DatabaseChannelState implements ChannelState {
  DatabaseChannelState(this.db, {required this.server, this.connection});

  final DatabaseManager db;
  final String server;
  final String? connection;

  /// How long a server may stay silent before its members stop counting.
  static const Duration liveness = Duration(seconds: 30);

  /// How long a cache channel keeps its last frame, as Pusher Channels.
  static const Duration cacheTtl = Duration(minutes: 30);

  static int get _now => Clock.now().toUtc().millisecondsSinceEpoch ~/ 1000;

  QueryBuilder _table(String name) => db.table(name, connection: connection);

  /// The servers whose members count: this one and those heard from lately.
  Future<List<String>> _liveServers() async {
    final rows = await _table('broadcast_servers')
        .where('seen_at', '>', _now - liveness.inSeconds)
        .select(['server'])
        .get();
    return {server, for (final row in rows) '${row['server']}'}.toList();
  }

  Future<List<Map<String, Object?>>> _members(String channel) async =>
      _table('broadcast_members')
          .where('channel', channel)
          .whereIn('server', await _liveServers())
          .orderBy('id')
          .get();

  /// Says this server is alive.
  Future<void> beat() => _table('broadcast_servers').upsert(
    <String, Object?>{'server': server, 'seen_at': _now},
    const ['server'],
  );

  /// Forgets servers silent for twice [liveness] with their members, relayed
  /// messages older than a minute and expired cache channels.
  Future<void> prune() async {
    final now = _now;
    final dead = [
      for (final row
          in await _table('broadcast_servers')
              .where('seen_at', '<=', now - 2 * liveness.inSeconds)
              .select(['server'])
              .get())
        '${row['server']}',
    ];
    if (dead.isNotEmpty) {
      await _table('broadcast_members').whereIn('server', dead).delete();
      await _table('broadcast_servers').whereIn('server', dead).delete();
    }
    await _table('broadcast_messages')
        .where('created_at', '<', now - 60)
        .delete();
    await _table('broadcast_cache').where('expires_at', '<=', now).delete();
  }

  @override
  Future<Object?> call(String op, Map<String, Object?> args) async {
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
        final rows = await _members(args['channel']! as String);
        return {
          'occupied': rows.isNotEmpty,
          'subscription_count': rows.length,
          'user_count': _users(rows).length,
        };
      case 'channels':
        final prefix = args['prefix'] as String? ?? '';
        final rows = await _table('broadcast_members')
            .whereIn('server', await _liveServers())
            .select(['channel'])
            .get();
        final counts = <String, int>{};
        for (final row in rows) {
          final name = '${row['channel']}';
          if (name.startsWith(prefix)) {
            counts[name] = (counts[name] ?? 0) + 1;
          }
        }
        return counts;
      case 'users':
        return _users(await _members(args['channel']! as String)).keys.toList();
      case 'connections':
        final rows = await _table('broadcast_members')
            .whereIn('server', await _liveServers())
            .select(['socket'])
            .get();
        return {for (final row in rows) row['socket']}.length;
      case 'cache_set':
        await _table('broadcast_cache').upsert(
          <String, Object?>{
            'channel': args['channel'],
            'frame': args['frame'],
            'expires_at': _now + cacheTtl.inSeconds,
          },
          const ['channel'],
        );
        return null;
      case 'cache_get':
        final row = await _table('broadcast_cache')
            .where('channel', args['channel'])
            .where('expires_at', '>', _now)
            .first();
        return row?['frame'];
    }
    throw StateError('Unknown channels operation [$op].');
  }

  Future<Map<String, Object?>> _join(
    String channel,
    String socket,
    String? userId,
    Object? userInfo,
  ) async {
    await _table('broadcast_members').insert(<String, Object?>{
      'server': server,
      'socket': socket,
      'channel': channel,
      'user_id': userId,
      'user_info': userInfo == null ? null : jsonEncode(userInfo),
      'created_at': _now,
    });
    if (userId == null) {
      return {'added': false, 'members': null};
    }
    final rows = await _members(channel);
    return {
      // The user's first connection on any server.
      'added': rows.where((row) => '${row['user_id']}' == userId).length == 1,
      'members': _users(rows),
    };
  }

  Future<Map<String, Object?>> _leave(String channel, String socket) async {
    final row = await _table('broadcast_members')
        .where('channel', channel)
        .where('socket', socket)
        .where('server', server)
        .first();
    if (row == null) {
      return {'removed': null};
    }
    await _table('broadcast_members').where('id', row['id']).delete();
    final userId = row['user_id'];
    if (userId == null) {
      return {'removed': null};
    }
    final others = (await _members(channel))
        .where((other) => '${other['user_id']}' == '$userId');
    return {
      // The user's last connection on any server.
      'removed': others.isEmpty ? '$userId' : null,
    };
  }

  /// user id → user info, in join order.
  static Map<String, Object?> _users(List<Map<String, Object?>> rows) {
    final users = <String, Object?>{};
    for (final row in rows) {
      final id = row['user_id'];
      if (id != null) {
        users.putIfAbsent('$id', () {
          final info = row['user_info'];
          return info is String ? jsonDecode(info) : null;
        });
      }
    }
    return users;
  }
}

/// Relays the Pusher server's frames between servers through the database
/// (`REVERB_SCALING_ENABLED`), as Reverb does through Redis: [send] stores
/// a frame, and every isolate of every other server reads it ([start]) and
/// hands it to its own connections.
///
/// PostgreSQL wakes the readers with `NOTIFY`; other databases are read
/// every [poll]. A reader looks back 64 ids, so a frame committed after a
/// later one (two servers inserting at once) is still delivered, once.
final class DatabaseBroadcastRelay {
  DatabaseBroadcastRelay(
    this.db, {
    required this.state,
    this.connection,
    this.poll = const Duration(milliseconds: 100),
    this.onError,
  });

  final DatabaseManager db;

  /// Sends the heartbeat and prunes as the relay runs.
  final DatabaseChannelState state;
  final String? connection;
  final Duration poll;
  final void Function(Object error)? onError;

  /// The notification that wakes the readers.
  static const String notification = 'daravel_broadcast';

  static const int _lookBack = 64;

  String get server => state.server;

  bool _running = false;
  bool _closed = false;
  Completer<void>? _wake;
  int _highest = 0;
  final Set<int> _delivered = <int>{};

  QueryBuilder get _messages =>
      db.table('broadcast_messages', connection: connection);

  /// Stores [envelope] (`<except socket>\n<frame>`) for the other servers.
  Future<void> send(String channel, String envelope) async {
    await _messages.insert(<String, Object?>{
      'origin': server,
      'channel': channel,
      'frame': envelope,
      'created_at': Clock.now().toUtc().millisecondsSinceEpoch ~/ 1000,
    });
    await db.notify(notification, '', connection);
  }

  /// Starts reading the other servers' frames into [deliver] until [close].
  Future<void> start(void Function(String channel, String envelope) deliver) {
    if (_running) {
      return Future<void>.value();
    }
    _running = true;
    final ready = Completer<void>();
    unawaited(_run(deliver, ready));
    return ready.future;
  }

  Future<void> _run(
    void Function(String channel, String envelope) deliver,
    Completer<void> ready,
  ) async {
    StreamSubscription<String>? wakeups;
    try {
      await state.beat();
      _highest = ((await _messages.max('id')) as num?)?.toInt() ?? 0;
      // Frames sent before this server started are not for its clients:
      // mark the ones the look-back would read again as delivered.
      await _read((_, _) {});
      final stream = await db.notifications(
        notification,
        connection: connection,
      );
      wakeups = stream?.listen((_) {
        final wake = _wake;
        if (wake != null && !wake.isCompleted) {
          wake.complete();
        }
      });
    } catch (error) {
      onError?.call(error);
    } finally {
      ready.complete();
    }
    var lastBeat = DateTime.now();
    var lastPrune = DateTime.now();
    while (!_closed) {
      try {
        await _read(deliver);
        final now = DateTime.now();
        if (now.difference(lastBeat) >= const Duration(seconds: 10)) {
          lastBeat = now;
          await state.beat();
        }
        if (now.difference(lastPrune) >= const Duration(minutes: 1)) {
          lastPrune = now;
          await state.prune();
        }
      } catch (error) {
        onError?.call(error);
      }
      // Notified servers still read once a second, in case one was missed.
      await _sleep(wakeups == null ? poll : const Duration(seconds: 1));
    }
    await wakeups?.cancel();
  }

  Future<void> _sleep(Duration duration) async {
    final wake = _wake = Completer<void>();
    final timer = Timer(duration, () {
      if (!wake.isCompleted) {
        wake.complete();
      }
    });
    await wake.future;
    timer.cancel();
    _wake = null;
  }

  Future<void> _read(
    void Function(String channel, String envelope) deliver,
  ) async {
    final rows = await _messages
        .where('id', '>', max(0, _highest - _lookBack))
        .orderBy('id')
        .limit(1000)
        .get();
    for (final row in rows) {
      final id = (row['id']! as num).toInt();
      if (!_delivered.add(id)) {
        continue;
      }
      _highest = max(_highest, id);
      if (row['origin'] != server) {
        deliver('${row['channel']}', '${row['frame']}');
      }
    }
    _delivered.removeWhere((id) => id <= _highest - 2 * _lookBack);
  }

  /// Stops reading.
  Future<void> close() async {
    _closed = true;
    final wake = _wake;
    if (wake != null && !wake.isCompleted) {
      wake.complete();
    }
  }
}

/// The tables of `REVERB_SCALING_ENABLED`: relayed frames, channel
/// members, server heartbeats and cache channels.
final class CreateBroadcastingTables extends Migration {
  const CreateBroadcastingTables();

  @override
  String get name => '0001_01_01_000003_create_broadcasting_tables';

  @override
  Future<void> up(SchemaBuilder schema) async {
    await schema.create('broadcast_messages', (table) {
      table.id();
      table.string('origin');
      table.string('channel');
      table.longText('frame');
      table.unsignedInteger('created_at').index();
    });
    await schema.create('broadcast_members', (table) {
      table.id();
      table.string('server').index();
      table.string('socket');
      table.string('channel').index();
      table.string('user_id').nullable();
      table.text('user_info').nullable();
      table.unsignedInteger('created_at');
    });
    await schema.create('broadcast_servers', (table) {
      table.string('server').primary();
      table.unsignedInteger('seen_at');
    });
    await schema.create('broadcast_cache', (table) {
      table.string('channel').primary();
      table.longText('frame');
      table.unsignedInteger('expires_at');
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    await schema.dropIfExists('broadcast_cache');
    await schema.dropIfExists('broadcast_servers');
    await schema.dropIfExists('broadcast_members');
    await schema.dropIfExists('broadcast_messages');
  }
}
