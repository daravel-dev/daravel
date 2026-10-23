import 'package:path/path.dart' as p;

import '../foundation/config.dart';
import '../foundation/env.dart';

/// A single named connection (`config/database.php` parity).
final class ConnectionConfig {
  const ConnectionConfig({
    required this.driver,
    required this.database,
    this.host,
    this.port,
    this.username,
    this.password,
    this.options = const <String, Object?>{},
  });

  final String driver;
  final String database;
  final String? host;
  final int? port;
  final String? username;
  final String? password;
  final Map<String, Object?> options;

  Map<String, Object?> toMap() => <String, Object?>{
    'driver': driver,
    'database': database,
    'host': host,
    'port': port,
    'username': username,
    'password': password == null ? null : '********',
    'options': options,
  };
}

/// Database configuration section.
final class DatabaseConfig implements ConfigSection {
  const DatabaseConfig({
    required this.defaultConnection,
    required this.connections,
  });

  /// Reads `DB_*` variables. `DB_CONNECTION` selects the default connection
  /// (`sqlite` by default). Relative SQLite paths resolve against [basePath].
  factory DatabaseConfig.fromEnv(Env env, {required String basePath}) {
    final defaultConnection = env.string('DB_CONNECTION', 'sqlite');
    final database = env.maybeString('DB_DATABASE');

    final sqlitePath = switch (database) {
      null || '' => p.join(basePath, 'database', 'database.sqlite'),
      ':memory:' => ':memory:',
      final value when value.startsWith('file:') || p.isAbsolute(value) =>
        value,
      final value => p.join(basePath, value),
    };

    return DatabaseConfig(
      defaultConnection: defaultConnection,
      connections: <String, ConnectionConfig>{
        'sqlite': ConnectionConfig(driver: 'sqlite', database: sqlitePath),
        'pgsql': ConnectionConfig(
          driver: 'pgsql',
          database: database ?? 'daravel',
          host: env.string('DB_HOST', '127.0.0.1'),
          port: env.integer('DB_PORT', 5432),
          username: env.maybeString('DB_USERNAME'),
          password: env.maybeString('DB_PASSWORD'),
        ),
        'mysql': ConnectionConfig(
          driver: 'mysql',
          database: database ?? 'daravel',
          host: env.string('DB_HOST', '127.0.0.1'),
          port: env.integer('DB_PORT', 3306),
          username: env.maybeString('DB_USERNAME'),
          password: env.maybeString('DB_PASSWORD'),
        ),
      },
    );
  }

  final String defaultConnection;
  final Map<String, ConnectionConfig> connections;

  @override
  String get key => 'database';

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'default': defaultConnection,
    'connections': <String, Object?>{
      for (final entry in connections.entries) entry.key: entry.value.toMap(),
    },
  };
}
