import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'config.dart';
import 'connection.dart';
import 'resp.dart';

/// A Lua script, sent by its SHA1 (`EVALSHA`) and loaded on `NOSCRIPT`.
final class RedisScript {
  RedisScript(this.source) : sha = sha1.convert(utf8.encode(source)).toString();

  final String source;
  final String sha;
}

/// The Redis Cluster hash slot of [key] (0 to 16383): CRC16 of the key, or
/// of its hash tag (the text between the first `{` and the next `}`, when
/// not empty), so `{user:7}:a` and `{user:7}:b` share a slot.
int redisHashSlot(String key) {
  var bytes = utf8.encode(key);
  final open = bytes.indexOf(0x7b);
  if (open >= 0) {
    final close = bytes.indexOf(0x7d, open + 1);
    if (close > open + 1) {
      bytes = bytes.sublist(open + 1, close);
    }
  }
  var crc = 0;
  for (final byte in bytes) {
    crc = ((crc << 8) & 0xff00) ^ _crc16[((crc >> 8) ^ byte) & 0xff];
  }
  return crc & 0x3fff;
}

/// CRC16-CCITT (XMODEM), the checksum Redis Cluster uses for slots.
final List<int> _crc16 = List<int>.generate(256, (i) {
  var crc = i << 8;
  for (var bit = 0; bit < 8; bit++) {
    crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : crc << 1;
  }
  return crc & 0xffff;
}, growable: false);

/// A Redis client for one isolate, for one server ([RedisNodeClient]: a
/// standalone server or Sentinel's master) or a Redis Cluster
/// ([RedisClusterClient]), as its [config] says.
///
/// Commands share one connection per server (replies are matched in order,
/// so concurrent commands pipeline), opened on first use and again after it
/// drops. Blocking commands and Pub/Sub take connections of their own
/// ([dedicated], [subscribe]).
abstract base class RedisClient {
  factory RedisClient(RedisConnectionConfig config) => switch (config.mode) {
    RedisMode.cluster => RedisClusterClient(config),
    RedisMode.standalone || RedisMode.sentinel => RedisNodeClient(config),
  };

  RedisClient._(this.config);

  final RedisConnectionConfig config;

  /// Sends one command (`['SET', 'key', 'value']`) and returns its reply:
  /// a `String`, `int`, `List`, `null`, ... An error reply throws
  /// [RedisCommandException]; a dropped connection or a timeout,
  /// [RedisConnectionException].
  Future<Object?> command(List<Object?> args, {Duration? timeout});

  /// Sends [commands] together and returns their replies in order, an
  /// error reply as a [RedisCommandException] in its place.
  Future<List<Object?>> pipeline(List<List<Object?>> commands);

  /// A connection of its own, for blocking commands (`BLPOP`) on [key]
  /// (whose server it reaches in a cluster), its pushes to [onMessage];
  /// closed with the client.
  Future<RedisConnection> dedicated({
    String? key,
    void Function(List<Object?> message)? onMessage,
  });

  /// A client of each master: this one on a single server, one per master
  /// of a cluster.
  Future<List<RedisNodeClient>> masterClients();

  /// Whether [close] was called.
  bool get isClosed;

  /// Messages published on [channels] (or matching them, with [pattern]),
  /// on a connection of its own that subscribes again after it drops.
  RedisSubscription subscribe(List<String> channels, {bool pattern = false});

  /// The keys matching [match] (a `SCAN` glob), on every master.
  Stream<String> scan({String? match, int count = 500});

  /// The hash slot of [key] in a cluster; null on one server, where every
  /// key is together.
  int? slot(String key) => null;

  /// What this client did: connections opened, commands waiting for
  /// replies, Sentinel or Cluster lookups and redirections.
  Map<String, Object?> get stats;

  /// Closes every connection of this client.
  Future<void> close();

  /// Runs [script] in one round trip: by its SHA1, or by its source the
  /// first time this server sees it.
  Future<Object?> eval(
    RedisScript script, {
    List<String> keys = const [],
    List<Object?> args = const [],
  }) async {
    try {
      return await command([
        'EVALSHA',
        script.sha,
        keys.length,
        ...keys,
        ...args,
      ]);
    } on RedisCommandException catch (error) {
      if (error.code != 'NOSCRIPT') {
        rethrow;
      }
      return command(['EVAL', script.source, keys.length, ...keys, ...args]);
    }
  }

  Future<String?> get(String key) async =>
      (await command(['GET', key])) as String?;

  /// `SET`; [ttl] sets `PX`, [onlyIfAbsent] `NX` (then `false` when the key
  /// existed).
  Future<bool> set(
    String key,
    Object value, {
    Duration? ttl,
    bool onlyIfAbsent = false,
  }) async =>
      await command([
        'SET',
        key,
        value,
        if (ttl != null) ...['PX', max(1, ttl.inMilliseconds)],
        if (onlyIfAbsent) 'NX',
      ]) ==
      'OK';

  Future<int> del(List<String> keys) async =>
      keys.isEmpty ? 0 : (await command(['DEL', ...keys]))! as int;

  /// `PUBLISH`: how many subscribers received [message].
  Future<int> publish(String channel, String message) async =>
      (await command(['PUBLISH', channel, message]))! as int;
}

/// One server: a standalone Redis or Valkey, or the master Sentinel
/// reports ([RedisMode.sentinel]).
///
/// With Sentinel, every connection asks the Sentinels for the master, then
/// checks with `ROLE` that the server is one; after a failover the old
/// master refuses writes (`READONLY`), and the refused command is sent
/// again to the new one (it did not run, so this is safe).
final class RedisNodeClient extends RedisClient {
  RedisNodeClient(super.config) : _sentinels = [...config.nodes], super._();

  RedisConnection? _connection;
  Future<RedisConnection>? _opening;
  bool _closed = false;
  final Set<RedisConnection> _dedicated = {};
  final Set<RedisSubscription> _subscriptions = {};

  /// The Sentinels, the last one that answered first.
  final List<RedisNode> _sentinels;
  int _connects = 0;
  int _failovers = 0;

  /// Opens a connection to the server (Sentinel's master, checked), with
  /// [onMessage] receiving its Pub/Sub messages and pushes.
  Future<RedisConnection> connect({
    void Function(List<Object?> message)? onMessage,
  }) async {
    final target = await _target();
    final connection = await RedisConnection.open(target, onMessage: onMessage);
    _connects++;
    if (config.mode == RedisMode.sentinel) {
      try {
        final role = await connection.send(['ROLE']);
        if (role is! List || role.isEmpty || role.first != 'master') {
          throw RedisConnectionException(
            '${target.host}:${target.port} is not the master of '
            '${config.sentinelService} (yet).',
          );
        }
      } on Object {
        await connection.close();
        rethrow;
      }
    }
    return connection;
  }

  /// The server to connect to: [config] itself, or the master that the
  /// first answering Sentinel names.
  Future<RedisConnectionConfig> _target() async {
    if (config.mode != RedisMode.sentinel) {
      return config;
    }
    Object? lastError;
    for (final sentinel in [..._sentinels]) {
      RedisConnection? connection;
      try {
        connection = await RedisConnection.open(
          config.node(sentinel.host, sentinel.port, sentinel: true),
        );
        final reply = await connection.send([
          'SENTINEL',
          'get-master-addr-by-name',
          config.sentinelService,
        ]);
        if (reply case [final String host, final Object? port]) {
          _sentinels
            ..remove(sentinel)
            ..insert(0, sentinel);
          return config.node(host, int.parse('$port'));
        }
        lastError = 'it does not know ${config.sentinelService}';
      } on Object catch (error) {
        lastError = error;
      } finally {
        await connection?.close();
      }
    }
    throw RedisConnectionException(
      'No Sentinel of ${config.redacted} names a master: $lastError',
    );
  }

  Future<RedisConnection> _open() {
    final current = _connection;
    if (current != null && !current.isClosed) {
      return Future.value(current);
    }
    if (_closed) {
      return Future.error(const RedisConnectionException('Client closed.'));
    }
    return _opening ??= connect()
        .then((connection) {
          _connection = connection;
          return connection;
        })
        .whenComplete(() => _opening = null);
  }

  /// Whether [error] says the server stopped being the master.
  bool _demoted(RedisCommandException error) =>
      config.mode == RedisMode.sentinel && error.code == 'READONLY';

  Future<void> _reconnect() async {
    _failovers++;
    final stale = _connection;
    _connection = null;
    await stale?.close();
  }

  @override
  Future<Object?> command(List<Object?> args, {Duration? timeout}) async {
    try {
      return await (await _open()).send(args, timeout: timeout);
    } on RedisCommandException catch (error) {
      if (!_demoted(error)) {
        rethrow;
      }
      await _reconnect();
      return (await _open()).send(args, timeout: timeout);
    }
  }

  @override
  Future<List<Object?>> pipeline(List<List<Object?>> commands) async {
    final connection = await _open();
    return Future.wait([
      for (final args in commands)
        connection
            .send(args)
            .then<Object?>(
              (reply) => reply,
              onError: (Object error, StackTrace stack) =>
                  error is RedisCommandException
                  ? error
                  : Error.throwWithStackTrace(error, stack),
            ),
    ]);
  }

  @override
  bool get isClosed => _closed;

  @override
  Future<List<RedisNodeClient>> masterClients() async => [this];

  @override
  Future<RedisConnection> dedicated({
    String? key,
    void Function(List<Object?> message)? onMessage,
  }) async {
    if (_closed) {
      throw const RedisConnectionException('Client closed.');
    }
    final connection = await connect(onMessage: onMessage);
    if (_closed) {
      await connection.close();
      throw const RedisConnectionException('Client closed.');
    }
    _dedicated.add(connection);
    unawaited(connection.done.then((_) => _dedicated.remove(connection)));
    return connection;
  }

  @override
  RedisSubscription subscribe(List<String> channels, {bool pattern = false}) {
    final subscription = RedisSubscription._(
      (onMessage) => connect(onMessage: onMessage),
      channels,
      pattern,
      connectTimeout: config.connectTimeout,
      onCancel: _subscriptions.remove,
    );
    _subscriptions.add(subscription);
    subscription._run();
    return subscription;
  }

  @override
  Stream<String> scan({String? match, int count = 500}) async* {
    var cursor = '0';
    do {
      final reply =
          (await command([
                'SCAN',
                cursor,
                if (match != null) ...['MATCH', match],
                'COUNT',
                count,
              ]))!
              as List;
      cursor = reply[0]! as String;
      for (final key in reply[1]! as List) {
        yield key! as String;
      }
    } while (cursor != '0');
  }

  @override
  Map<String, Object?> get stats => {
    'mode': config.mode.name,
    'server': _connection == null
        ? null
        : '${_connection!.config.host}:${_connection!.config.port}',
    'connected': _connection != null && !_connection!.isClosed,
    'connects': _connects,
    'in_flight': _connection?.inFlight ?? 0,
    'dedicated': _dedicated.length,
    'subscriptions': _subscriptions.length,
    if (config.mode == RedisMode.sentinel) 'failovers': _failovers,
  };

  @override
  Future<void> close() async {
    _closed = true;
    for (final subscription in [..._subscriptions]) {
      await subscription.cancel();
    }
    for (final connection in [..._dedicated]) {
      await connection.close();
    }
    await _connection?.close();
    _connection = null;
  }
}

/// A Redis Cluster: each command goes to the master serving the hash slot
/// of its key, from a slot map read with `CLUSTER SLOTS` and corrected by
/// `MOVED` and `ASK` replies. `MGET`, `DEL`, `UNLINK`, `EXISTS` and
/// `TOUCH` over keys of several slots are split per slot; other commands
/// over several slots are refused by the server (`CROSSSLOT`), which is
/// why Daravel's own keys share a hash tag per atomic unit.
///
/// Commands without a key (`PING`, `PUBLISH`, `INFO`) go to one master;
/// Pub/Sub reaches the whole cluster from any node.
final class RedisClusterClient extends RedisClient {
  RedisClusterClient(super.config) : super._();

  /// Clients of each node, by `host:port`.
  final Map<String, RedisNodeClient> _nodes = {};

  /// The master of each slot (`host:port`, empty when none serves it).
  List<String>? _slots;
  Future<void>? _refreshing;
  final Set<RedisSubscription> _subscriptions = {};
  int _refreshes = 0;
  int _redirects = 0;

  static const int _maxRedirects = 5;

  /// Commands whose keys may be split across slots.
  static const Set<String> _splittable = {
    'MGET',
    'DEL',
    'UNLINK',
    'EXISTS',
    'TOUCH',
  };

  @override
  int slot(String key) => redisHashSlot(key);

  RedisNodeClient _node(String address) {
    final colon = address.lastIndexOf(':');
    return _nodes[address] ??= RedisNodeClient(
      config.node(
        address.substring(0, colon),
        int.parse(address.substring(colon + 1)),
      ),
    );
  }

  /// The masters serving slots, by `host:port`.
  Future<List<String>> masters() async {
    await _ensureMap();
    return {..._slots!.where((address) => address.isNotEmpty)}.toList();
  }

  Future<void> _ensureMap() async {
    if (_slots == null) {
      await refresh();
    }
  }

  /// Reads the slot map again, from the first node that answers.
  Future<void> refresh() =>
      _refreshing ??= _refresh().whenComplete(() => _refreshing = null);

  Future<void> _refresh() async {
    final seeds = {for (final n in config.nodes) '${n.host}:${n.port}'};
    final known = _slots == null ? const <String>{} : {..._slots!};
    Object? lastError;
    for (final address in {...known.where((a) => a.isNotEmpty), ...seeds}) {
      try {
        final reply = await _node(address).command(['CLUSTER', 'SLOTS']);
        final host = address.substring(0, address.lastIndexOf(':'));
        final slots = List<String>.filled(16384, '');
        for (final range in reply! as List) {
          if (range case [
            final int start,
            final int end,
            [final String nodeHost, final int port, ...],
            ...,
          ]) {
            final master = nodeHost.isEmpty || nodeHost == '?'
                ? host
                : nodeHost;
            slots.fillRange(start, end + 1, '$master:$port');
          }
        }
        _slots = slots;
        _refreshes++;
        final serving = {...slots};
        for (final gone in [
          for (final a in _nodes.keys)
            if (!serving.contains(a) && !seeds.contains(a)) a,
        ]) {
          unawaited(_nodes.remove(gone)!.close());
        }
        return;
      } on Object catch (error) {
        lastError = error;
      }
    }
    throw RedisConnectionException(
      'No node of ${config.redacted} answers CLUSTER SLOTS: $lastError',
    );
  }

  /// The master of [slot], or any master for a command without a key.
  Future<String> _address(int? slot) async {
    await _ensureMap();
    if (slot == null) {
      final masters = await this.masters();
      if (masters.isEmpty) {
        throw const RedisCommandException('CLUSTERDOWN No master serves slots');
      }
      return masters.first;
    }
    var address = _slots![slot];
    if (address.isEmpty) {
      await refresh();
      address = _slots![slot];
    }
    if (address.isEmpty) {
      throw RedisCommandException('CLUSTERDOWN Hash slot $slot not served');
    }
    return address;
  }

  /// The keys of a command, as far as routing needs them.
  static List<String> keysOf(List<Object?> args) {
    if (args.length < 2) {
      return const [];
    }
    String at(int i) => '${args[i]}';
    switch ('${args.first}'.toUpperCase()) {
      case 'PING' ||
          'ECHO' ||
          'INFO' ||
          'TIME' ||
          'SCAN' ||
          'PUBLISH' ||
          'CLUSTER' ||
          'CONFIG' ||
          'DBSIZE' ||
          'FLUSHDB' ||
          'FLUSHALL' ||
          'SCRIPT' ||
          'CLIENT' ||
          'COMMAND' ||
          'ROLE' ||
          'WAIT' ||
          'HELLO' ||
          'AUTH' ||
          'SELECT':
        return const [];
      case 'EVAL' ||
          'EVALSHA' ||
          'EVAL_RO' ||
          'EVALSHA_RO' ||
          'FCALL' ||
          'FCALL_RO':
        final count = args.length > 2 ? int.tryParse(at(2)) ?? 0 : 0;
        return [for (var i = 3; i < 3 + count && i < args.length; i++) at(i)];
      case 'BLPOP' || 'BRPOP' || 'BZPOPMIN' || 'BZPOPMAX' || 'BLMPOP'
          when args.length > 2:
        return [for (var i = 1; i < args.length - 1; i++) at(i)];
      case 'XREAD' || 'XREADGROUP':
        final streams = args.indexWhere((a) => '$a'.toUpperCase() == 'STREAMS');
        if (streams < 0) {
          return const [];
        }
        final count = (args.length - streams - 1) ~/ 2;
        return [for (var i = streams + 1; i <= streams + count; i++) at(i)];
      case 'MGET' ||
          'DEL' ||
          'UNLINK' ||
          'EXISTS' ||
          'TOUCH' ||
          'WATCH' ||
          'SINTER' ||
          'SUNION' ||
          'SDIFF' ||
          'PFCOUNT':
        return [for (var i = 1; i < args.length; i++) at(i)];
      case 'MSET' || 'MSETNX':
        return [for (var i = 1; i < args.length; i += 2) at(i)];
      case 'OBJECT' || 'MEMORY' || 'XGROUP' || 'XINFO' when args.length > 2:
        return [at(2)];
      default:
        return [at(1)];
    }
  }

  @override
  Future<Object?> command(List<Object?> args, {Duration? timeout}) async {
    final keys = keysOf(args);
    final name = '${args.first}'.toUpperCase();
    if (keys.length > 1 && _splittable.contains(name)) {
      final bySlot = <int, List<int>>{};
      for (var i = 0; i < keys.length; i++) {
        bySlot.putIfAbsent(slot(keys[i]), () => []).add(i);
      }
      if (bySlot.length > 1) {
        final groups = bySlot.entries.toList();
        final parts = await Future.wait([
          for (final MapEntry(key: slot, value: indexes) in groups)
            _send(slot, [
              args.first,
              for (final i in indexes) keys[i],
            ], timeout),
        ]);
        if (name == 'MGET') {
          final values = List<Object?>.filled(keys.length, null);
          for (var g = 0; g < groups.length; g++) {
            final indexes = groups[g].value;
            final part = parts[g]! as List;
            for (var k = 0; k < indexes.length; k++) {
              values[indexes[k]] = part[k];
            }
          }
          return values;
        }
        return parts.fold<int>(0, (sum, part) => sum + (part! as int));
      }
    }
    return _send(keys.isEmpty ? null : slot(keys.first), args, timeout);
  }

  Future<Object?> _send(
    int? slot,
    List<Object?> args,
    Duration? timeout, {
    int redirects = 0,
    String? asking,
  }) async {
    final address = asking ?? await _address(slot);
    final node = _node(address);
    try {
      if (asking != null) {
        final replies = await node.pipeline([
          ['ASKING'],
          args,
        ]);
        final reply = replies[1];
        if (reply is RedisCommandException) {
          throw reply;
        }
        return reply;
      }
      return await node.command(args, timeout: timeout);
    } on RedisCommandException catch (error) {
      if (redirects >= _maxRedirects) {
        rethrow;
      }
      switch (error.code) {
        case 'MOVED' || 'ASK':
          // MOVED 3999 127.0.0.1:6381 (an empty host: the replying node's).
          final parts = error.message.split(' ');
          final target = parts.length > 2 ? parts[2] : '';
          final colon = target.lastIndexOf(':');
          final to = colon == 0
              ? '${address.substring(0, address.lastIndexOf(':'))}$target'
              : target;
          _redirects++;
          if (error.code == 'MOVED') {
            final moved = int.tryParse(parts.length > 1 ? parts[1] : '');
            if (moved != null && _slots != null) {
              _slots![moved] = to;
            }
            unawaited(refresh().catchError((Object _) {}));
            return _send(slot, args, timeout, redirects: redirects + 1);
          }
          return _send(
            slot,
            args,
            timeout,
            redirects: redirects + 1,
            asking: to,
          );
        case 'TRYAGAIN':
          // A slot being migrated: its keys are briefly split.
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return _send(slot, args, timeout, redirects: redirects + 1);
      }
      rethrow;
    } on RedisConnectionException {
      // The node may have failed over: read the map again for next time.
      unawaited(refresh().catchError((Object _) {}));
      rethrow;
    }
  }

  @override
  Future<List<Object?>> pipeline(List<List<Object?>> commands) => Future.wait([
    for (final args in commands)
      command(args).then<Object?>(
        (reply) => reply,
        onError: (Object error, StackTrace stack) =>
            error is RedisCommandException
            ? error
            : Error.throwWithStackTrace(error, stack),
      ),
  ]);

  @override
  Future<RedisConnection> dedicated({
    String? key,
    void Function(List<Object?> message)? onMessage,
  }) async =>
      _node(await _address(key == null ? null : slot(key)))
          .dedicated(onMessage: onMessage);

  @override
  Future<List<RedisNodeClient>> masterClients() async => [
    for (final address in await masters()) _node(address),
  ];

  @override
  bool get isClosed => _closed;
  bool _closed = false;

  @override
  RedisSubscription subscribe(List<String> channels, {bool pattern = false}) {
    final subscription = RedisSubscription._(
      (onMessage) async =>
          _node(await _address(null)).connect(onMessage: onMessage),
      channels,
      pattern,
      connectTimeout: config.connectTimeout,
      onCancel: _subscriptions.remove,
    );
    _subscriptions.add(subscription);
    subscription._run();
    return subscription;
  }

  @override
  Stream<String> scan({String? match, int count = 500}) async* {
    for (final address in await masters()) {
      yield* _node(address).scan(match: match, count: count);
    }
  }

  @override
  Map<String, Object?> get stats => {
    'mode': config.mode.name,
    'masters': _slots == null
        ? 0
        : {..._slots!.where((a) => a.isNotEmpty)}.length,
    'slot_map_reads': _refreshes,
    'redirects': _redirects,
    'subscriptions': _subscriptions.length,
    'nodes': {
      for (final MapEntry(key: address, value: node) in _nodes.entries)
        address: node.stats,
    },
  };

  @override
  Future<void> close() async {
    _closed = true;
    for (final subscription in [..._subscriptions]) {
      await subscription.cancel();
    }
    for (final node in _nodes.values) {
      await node.close();
    }
    _nodes.clear();
  }
}

/// A Pub/Sub message.
final class RedisMessage {
  const RedisMessage(this.channel, this.payload, {this.pattern});

  final String channel;
  final String payload;

  /// The pattern it matched (`PSUBSCRIBE`).
  final String? pattern;
}

/// A subscription that survives dropped connections (messages published
/// while it reconnects are lost: Pub/Sub is at most once).
final class RedisSubscription {
  RedisSubscription._(
    this._connect,
    this.channels,
    this.pattern, {
    required this._connectTimeout,
    required this._onCancel,
  });

  final Future<RedisConnection> Function(
    void Function(List<Object?> message) onMessage,
  )
  _connect;
  final Duration _connectTimeout;
  final void Function(RedisSubscription subscription) _onCancel;
  final List<String> channels;
  final bool pattern;
  final StreamController<RedisMessage> _messages =
      StreamController<RedisMessage>.broadcast();
  final Completer<void> _ready = Completer<void>();
  RedisConnection? _connection;
  bool _cancelled = false;

  /// The messages, as they arrive.
  Stream<RedisMessage> get messages => _messages.stream;

  /// Completes once the server confirmed the first subscription.
  Future<void> get ready => _ready.future;

  void _run() => unawaited(_loop());

  Future<void> _loop() async {
    var backoff = const Duration(milliseconds: 100);
    final random = Random();
    while (!_cancelled) {
      try {
        final confirmed = Completer<void>();
        final connection = await _connect(
          (message) => _onMessage(message, confirmed),
        );
        if (_cancelled) {
          await connection.close();
          return;
        }
        _connection = connection..subscriber = true;
        connection.write([pattern ? 'PSUBSCRIBE' : 'SUBSCRIBE', ...channels]);
        await confirmed.future.timeout(_connectTimeout);
        if (!_ready.isCompleted) {
          _ready.complete();
        }
        backoff = const Duration(milliseconds: 100);
        await connection.done;
      } on Object {
        // Reconnect below.
      }
      if (_cancelled) {
        return;
      }
      // Full jitter, up to five seconds.
      await Future<void>.delayed(
        Duration(milliseconds: random.nextInt(backoff.inMilliseconds + 1)),
      );
      backoff = Duration(milliseconds: min(5000, backoff.inMilliseconds * 2));
    }
  }

  void _onMessage(List<Object?> message, Completer<void> confirmed) {
    switch (message) {
      case ['subscribe' || 'psubscribe', ...]:
        if (!confirmed.isCompleted) {
          confirmed.complete();
        }
      case ['message', final String channel, final String payload]:
        _messages.add(RedisMessage(channel, payload));
      case [
        'pmessage',
        final String pattern,
        final String channel,
        final String payload,
      ]:
        _messages.add(RedisMessage(channel, payload, pattern: pattern));
    }
  }

  Future<void> cancel() async {
    _cancelled = true;
    _onCancel(this);
    await _connection?.close();
    await _messages.close();
  }
}

/// The Redis clients of this isolate, by connection name (`default`,
/// `cache`); bound in the container by `withRedis()`.
final class RedisManager {
  RedisManager(this.config);

  final RedisConfig config;
  final Map<String, RedisClient> _clients = {};

  RedisClient connection([String name = 'default']) =>
      _clients[name] ??= RedisClient(config.connection(name));

  /// The clients opened so far, by connection name.
  Map<String, RedisClient> get clients => Map.unmodifiable(_clients);

  Future<void> close() async {
    for (final client in _clients.values) {
      await client.close();
    }
    _clients.clear();
  }
}
