import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;

import 'config.dart';
import 'handlers.dart';
import 'session.dart';

/// Builds the [SessionHandler] of the configured driver and a [Session]
/// per request (Laravel's `SessionManager`).
final class SessionManager {
  SessionManager(this.config, {required this.basePath});

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
      'array' => ArraySessionHandler(lifetime: config.lifetime),
      final other => throw ConfigException(
        'SESSION_DRIVER=$other is not file, database or array, and no '
        'package registered it (SessionManager.extend).',
      ),
    };
  }

  /// A session for the id the request's cookie carried (or a new one).
  Session session([String? id]) =>
      Session(name: config.cookie, handler: handler, id: id);
}
