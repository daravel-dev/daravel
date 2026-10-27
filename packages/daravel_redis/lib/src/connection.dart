import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';

import 'config.dart';
import 'resp.dart';

/// One socket to Redis or Valkey (RESP2).
///
/// Commands are written as they come and replies matched in order, so
/// commands sent without awaiting each other share round trips
/// (pipelining); writes made in the same microtask leave in one packet. A
/// command that times out closes the connection, since the replies after
/// it could no longer be matched.
///
/// A connection in subscriber mode ([subscriber]) hands every message to
/// [onMessage] instead.
final class RedisConnection {
  RedisConnection._(this._socket, this.config, {this.onMessage}) {
    _socket.setOption(SocketOption.tcpNoDelay, true);
    _decoder = RespDecoder(_onValue);
    _subscription = _socket.listen(
      (chunk) {
        try {
          _decoder.add(chunk);
        } on FormatException catch (error) {
          _fail(RedisConnectionException('Malformed reply: ${error.message}'));
          unawaited(close());
        }
      },
      onError: (Object error) =>
          _fail(RedisConnectionException('Connection failed: $error')),
      onDone: () => _fail(const RedisConnectionException('Connection closed.')),
      cancelOnError: true,
    );
  }

  /// Opens a connection and authenticates (`AUTH`), then selects the
  /// database (`SELECT`).
  static Future<RedisConnection> open(
    RedisConnectionConfig config, {
    void Function(List<Object?> message)? onMessage,
  }) async {
    final connection = RedisConnection._(
      await _connect(config),
      config,
      onMessage: onMessage,
    );
    try {
      final password = config.password;
      if (password != null && password.isNotEmpty) {
        await connection.send([
          'AUTH',
          if (config.username case final String user when user.isNotEmpty) user,
          password,
        ]);
      }
      if (config.database != 0) {
        await connection.send(['SELECT', config.database]);
      }
    } on Object {
      await connection.close();
      rethrow;
    }
    return connection;
  }

  static Future<Socket> _connect(RedisConnectionConfig config) async {
    try {
      return config.tls
          ? await SecureSocket.connect(
              config.host,
              config.port,
              timeout: config.connectTimeout,
            )
          : await Socket.connect(
              config.host,
              config.port,
              timeout: config.connectTimeout,
            );
    } on Object catch (error) {
      throw RedisConnectionException(
        'Cannot connect to ${config.redacted}: $error',
      );
    }
  }

  final Socket _socket;
  final RedisConnectionConfig config;
  late final RespDecoder _decoder;
  late final StreamSubscription<Uint8List> _subscription;
  final Queue<Completer<Object?>> _pending = Queue<Completer<Object?>>();
  final BytesBuilder _out = BytesBuilder(copy: false);
  bool _flushScheduled = false;
  bool _closed = false;

  /// Messages of a subscriber connection (`message`, `pmessage`,
  /// `subscribe` confirmations, ...).
  final void Function(List<Object?> message)? onMessage;

  /// Whether replies go to [onMessage] (after `SUBSCRIBE`).
  bool subscriber = false;

  final Completer<void> _done = Completer<void>();

  /// Completes when the connection closes, for whatever reason.
  Future<void> get done => _done.future;

  bool get isClosed => _closed;

  /// Commands waiting for their replies.
  int get inFlight => _pending.length;

  /// Sends [args] and returns the reply; an error reply throws
  /// [RedisCommandException]. [timeout] defaults to the connection's
  /// command timeout; `Duration.zero` waits without limit (blocking
  /// commands).
  Future<Object?> send(List<Object?> args, {Duration? timeout}) {
    if (_closed) {
      return Future<Object?>.error(
        const RedisConnectionException('Connection closed.'),
      );
    }
    if (_pending.length >= config.maxInFlight) {
      return Future<Object?>.error(
        RedisOverloadedException(
          '${_pending.length} commands are waiting on ${config.redacted}.',
        ),
      );
    }
    final reply = Completer<Object?>();
    _pending.add(reply);
    _write(encodeCommand(args));
    final limit = timeout ?? config.commandTimeout;
    if (limit == Duration.zero) {
      return reply.future;
    }
    return reply.future.timeout(
      limit,
      onTimeout: () {
        // The replies after this one could no longer be matched.
        unawaited(close());
        throw RedisConnectionException(
          '${args.first} timed out after ${limit.inMilliseconds}ms.',
        );
      },
    );
  }

  /// Writes [args] without waiting for a reply (`SUBSCRIBE` on a
  /// subscriber connection).
  void write(List<Object?> args) {
    if (!_closed) {
      _write(encodeCommand(args));
    }
  }

  void _write(Uint8List bytes) {
    _out.add(bytes);
    if (!_flushScheduled) {
      _flushScheduled = true;
      scheduleMicrotask(() {
        _flushScheduled = false;
        if (!_closed && _out.isNotEmpty) {
          _socket.add(_out.takeBytes());
        }
      });
    }
  }

  void _onValue(Object? value) {
    // A subscriber connection only receives messages (commands go out with
    // [write]); a RESP3 push is never a reply either.
    if (subscriber || value is RespPush) {
      final items = value is RespPush ? value.items : value;
      if (items is List<Object?>) {
        onMessage?.call(items);
      }
      return;
    }
    if (_pending.isEmpty) {
      return;
    }
    final reply = _pending.removeFirst();
    if (value is RespError) {
      reply.completeError(RedisCommandException(value.message));
    } else {
      reply.complete(value);
    }
  }

  void _fail(RedisConnectionException error) {
    _closed = true;
    while (_pending.isNotEmpty) {
      final reply = _pending.removeFirst();
      if (!reply.isCompleted) {
        reply.completeError(error);
      }
    }
    if (!_done.isCompleted) {
      _done.complete();
    }
  }

  Future<void> close() async {
    if (_destroyed) {
      return;
    }
    _destroyed = true;
    _fail(const RedisConnectionException('Connection closed.'));
    await _subscription.cancel();
    _socket.destroy();
  }

  bool _destroyed = false;
}
