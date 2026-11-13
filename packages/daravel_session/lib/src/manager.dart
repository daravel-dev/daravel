import 'dart:async';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'handlers.dart';
import 'session.dart';

/// Builds the [SessionHandler] of the configured driver and a [Session]
/// per request (Laravel's `SessionManager`).
final class SessionManager {
  /// A manager of sessions with [config], files under [basePath].
  SessionManager(this.config, {required this.basePath});

  /// The session settings.
  final SessionConfig config;

  /// The application's base path, which `SESSION_FILES` is relative to.
  final String basePath;
  final Map<String, SessionHandler Function(SessionConfig)> _drivers = {};
  SessionHandler? _handler;

  /// Registers (or replaces) the handler of [driver]
  /// (`SESSION_DRIVER=redis` with a package that provides one).
  void extend(String driver, SessionHandler Function(SessionConfig) factory) {
    _drivers[driver] = factory;
    if (config.driver == driver) {
      _handler = null;
    }
  }

  /// The handler of `SESSION_DRIVER`, created once.
  SessionHandler get handler => _handler ??= _create();

  /// Sweeps expired sessions of [handler] outside the requests that win
  /// the lottery.
  late final SessionGarbageCollector garbageCollector = SessionGarbageCollector(
    () => handler,
    config.lifetime,
  );

  SessionHandler _create() {
    final custom = _drivers[config.driver];
    if (custom != null) {
      return custom(config);
    }
    return switch (config.driver) {
      'file' => FileSessionHandler(
        p.isAbsolute(config.files)
            ? config.files
            : p.join(basePath, config.files),
        lifetime: config.lifetime,
      ),
      'database' => DatabaseSessionHandler(
        table: config.table,
        connection: config.connection,
        lifetime: config.lifetime,
      ),
      'cache' => CacheSessionHandler(
        Cache.store(config.store),
        lifetime: config.lifetime,
      ),
      'array' => ArraySessionHandler(lifetime: config.lifetime),
      'redis' => throw ConfigException(
        'SESSION_DRIVER=redis needs daravel_redis: add withRedis() to the '
        'application.',
      ),
      final other => throw ConfigException(
        'SESSION_DRIVER=$other is not file, database, cache or array, and '
        'no package registered it (SessionManager.extend).',
      ),
    };
  }

  /// A session for the id the request's cookie carried (or a new one).
  Session session([String? id]) => Session(
    name: config.cookie,
    handler: handler,
    id: id,
    encrypter: config.encrypt ? Crypt.encrypter : null,
    serialization: config.serialization,
  );
}

/// Runs [SessionHandler.gc] for the requests that win the session lottery,
/// without making them wait: Laravel's `StartSession` sweeps before the
/// request, which holds one PHP worker, while here it would hold every
/// request of the isolate.
///
/// One sweep at a time per application: a lottery won while one runs is
/// ignored. The sweeps run detached (`runDetached`), with the
/// application's container and no request scope or transaction, their
/// errors going to the application's logger, and the application's
/// shutdown waits for the one in progress and starts no other.
final class SessionGarbageCollector {
  /// Sweeps the sessions of [handler] idle for longer than [lifetime].
  SessionGarbageCollector(this._handler, this.lifetime);

  final SessionHandler Function() _handler;

  /// How long a session lasts.
  final Duration lifetime;

  Detached<Zone>? _task;
  Future<void>? _running;
  bool _stopped = false;

  /// The sweep in progress, or null: tests await it.
  Future<void>? get running => _running;

  /// Starts a sweep unless one runs or the application stopped; returns
  /// the sweep in progress, which never fails (its error is logged).
  Future<void>? trigger() {
    if (_stopped || _running != null) {
      return _running;
    }
    // Registered once with the application; each sweep runs in its zone.
    final task = _task ??= runDetached<Zone>(
      () => Zone.current,
      name: 'session gc',
      stop: (_) => _stop(),
    );
    final sweep = task.value.run(_sweep);
    _running = sweep;
    return sweep;
  }

  Future<void> _sweep() async {
    try {
      await _handler().gc(lifetime);
    } on Object catch (error, stackTrace) {
      // To the detached zone's handler: the application's logger.
      Zone.current.handleUncaughtError(error, stackTrace);
    } finally {
      _running = null;
    }
  }

  Future<void> _stop() async {
    _stopped = true;
    await _running;
  }
}
