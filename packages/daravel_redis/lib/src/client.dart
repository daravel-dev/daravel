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

/// A Redis client for one isolate: one connection shared by every command
/// (replies are matched in order, so concurrent commands pipeline), opened
/// on first use and again after it drops. Blocking commands and Pub/Sub
/// take connections of their own ([dedicated], [subscribe]).
final class RedisClient {
  RedisClient(this.config);

  final RedisConnectionConfig config;
  RedisConnection? _connection;
  Future<RedisConnection>? _opening;
  bool _closed = false;
  final Set<RedisConnection> _dedicated = {};
  final Set<RedisSubscription> _subscriptions = {};

  Future<RedisConnection> _open() {
    final current = _connection;
    if (current != null && !current.isClosed) {
      return Future.value(current);
    }
    if (_closed) {
      return Future.error(const RedisConnectionException('Client closed.'));
    }
    return _opening ??= RedisConnection.open(config)
        .then((connection) {
          _connection = connection;
          return connection;
        })
        .whenComplete(() => _opening = null);
  }

  /// Sends one command (`['SET', 'key', 'value']`) and returns its reply:
  /// a `String`, `int`, `List`, `null`, ... An error reply throws
  /// [RedisCommandException]; a dropped connection or a timeout,
  /// [RedisConnectionException].
  Future<Object?> command(List<Object?> args, {Duration? timeout}) async =>
      (await _open()).send(args, timeout: timeout);

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

  /// A connection of its own, for blocking commands (`BLPOP`); closed with
  /// the client.
  Future<RedisConnection> dedicated() async {
    final connection = await RedisConnection.open(config);
    _dedicated.add(connection);
    unawaited(connection.done.then((_) => _dedicated.remove(connection)));
    return connection;
  }

  /// Messages published on [channels] (or matching them, with [pattern]),
  /// on a connection of its own that subscribes again after it drops.
  RedisSubscription subscribe(List<String> channels, {bool pattern = false}) {
    final subscription = RedisSubscription._(this, channels, pattern);
    _subscriptions.add(subscription);
    subscription._run();
    return subscription;
  }

  /// Closes every connection of this client.
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
  RedisSubscription._(this._client, this.channels, this.pattern);

  final RedisClient _client;
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
        final connection = await RedisConnection.open(
          _client.config,
          onMessage: (message) => _onMessage(message, confirmed),
        );
        if (_cancelled) {
          await connection.close();
          return;
        }
        _connection = connection..subscriber = true;
        connection.write([pattern ? 'PSUBSCRIBE' : 'SUBSCRIBE', ...channels]);
        await confirmed.future.timeout(_client.config.connectTimeout);
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
    _client._subscriptions.remove(this);
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

  Future<void> close() async {
    for (final client in _clients.values) {
      await client.close();
    }
    _clients.clear();
  }
}
