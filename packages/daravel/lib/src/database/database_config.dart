import 'package:path/path.dart' as p;

import '../foundation/config.dart';
import '../foundation/config_validator.dart';
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

  /// This connection with what [url] gives, merged as Laravel 12's
  /// `ConfigurationUrlParser` does for `DB_URL`: the scheme sets the driver
  /// (`postgres`/`postgresql` → `pgsql`, `mysql2` → `mysql`, `sqlite3` →
  /// `sqlite`), the host, port, user, password and database it contains
  /// replace this connection's, and its query string adds options. Parts
  /// the URL leaves out keep their values.
  ConnectionConfig withUrl(String url, {String basePath = '.'}) {
    if (url.startsWith('sqlite:') || url.startsWith('sqlite3:')) {
      final file = ConnectionConfig.fromUrl(
        'sqlite:${url.substring(url.indexOf(':') + 1)}',
        basePath: basePath,
      );
      return ConnectionConfig(
        driver: 'sqlite',
        database: file.database,
        options: options,
      );
    }
    final uri = Uri.parse(url);
    final driver = switch (uri.scheme) {
      'postgres' || 'postgresql' => 'pgsql',
      'mysql2' => 'mysql',
      '' => this.driver,
      final scheme => scheme,
    };
    final user = uri.userInfo.isEmpty ? null : uri.userInfo.split(':');
    final database = uri.path.length > 1 ? uri.path.substring(1) : null;
    return ConnectionConfig(
      driver: driver,
      database: database == null
          ? this.database
          : Uri.decodeComponent(database),
      host: uri.host.isEmpty ? host : uri.host,
      port: uri.hasPort ? uri.port : port,
      username: user == null ? username : Uri.decodeComponent(user.first),
      password: user == null || user.length < 2
          ? password
          : Uri.decodeComponent(user.sublist(1).join(':')),
      options: <String, Object?>{
        ...options,
        for (final MapEntry(:key, :value) in uri.queryParameters.entries)
          key: _native(value),
      },
    );
  }

  /// A query value as PHP's `parseStringsToNativeTypes` reads it.
  static Object? _native(String value) => switch (value) {
    'true' => true,
    'false' => false,
    'null' => null,
    _ => int.tryParse(value) ?? double.tryParse(value) ?? value,
  };

  /// [url] with its password masked, for messages: the error of a
  /// malformed `DB_URL` reaches `doctor`'s output, the boot log and error
  /// trackers, where `user:secret@` must not.
  static String redactUrl(String url) =>
      url.replaceFirstMapped(RegExp(r'^([a-z]+://[^:/@]*):[^@/]*@'), (m) {
        return '${m.group(1)}:***@';
      });

  /// A connection from a URL, as Laravel's `DB_URL`:
  /// `pgsql://user:secret@host:5432/app?sslmode=require&pool=5`,
  /// `mysql://user@host/app`, `mariadb://...`, `sqlite:database/app.sqlite`
  /// or `sqlite::memory:`. User and password are URL-decoded; a relative
  /// SQLite path resolves against [basePath].
  factory ConnectionConfig.fromUrl(String url, {String basePath = '.'}) {
    if (url.startsWith('sqlite:')) {
      var path = url.substring('sqlite:'.length);
      if (path.startsWith('//')) {
        path = path.substring(2); // sqlite:///abs/path is /abs/path
      }
      if (path.isEmpty) {
        throw FormatException('No SQLite file in "${redactUrl(url)}".');
      }
      return ConnectionConfig(
        driver: 'sqlite',
        database: path == ':memory:' || p.isAbsolute(path)
            ? path
            : p.join(basePath, path),
      );
    }
    final uri = Uri.tryParse(url);
    final driver = switch (uri?.scheme) {
      'pgsql' || 'postgres' || 'postgresql' => 'pgsql',
      'mysql' => 'mysql',
      'mariadb' => 'mariadb',
      _ => null,
    };
    if (uri == null || driver == null) {
      throw FormatException(
        'Not a database URL: "${redactUrl(url)}" (pgsql://, mysql://, '
        'mariadb:// or sqlite:).',
      );
    }
    final database = uri.pathSegments.where((s) => s.isNotEmpty).join('/');
    if (database.isEmpty) {
      throw FormatException('No database name in "${redactUrl(url)}".');
    }
    final user = uri.userInfo.split(':');
    final query = uri.queryParameters;
    return ConnectionConfig(
      driver: driver,
      database: Uri.decodeComponent(database),
      host: uri.host.isEmpty ? '127.0.0.1' : uri.host,
      port: uri.hasPort ? uri.port : (driver == 'pgsql' ? 5432 : 3306),
      username: user.first.isEmpty ? null : Uri.decodeComponent(user.first),
      password: user.length > 1
          ? Uri.decodeComponent(user.sublist(1).join(':'))
          : null,
      options: <String, Object?>{
        'pool': int.tryParse(query['pool'] ?? '') ?? 10,
        'sslmode': query['sslmode'] ?? 'disable',
        if (driver != 'pgsql') ...{
          'charset': query['charset'] ?? 'utf8mb4',
          'collation': query['collation'] ?? 'utf8mb4_unicode_ci',
          'timezone': query['timezone'],
        },
      },
    );
  }

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
  /// Boot check: `DB_CONNECTION` must name a configured connection.
  static Iterable<ConfigIssue> check(Env env, ConfigRepository config) {
    if (!config.hasSection<DatabaseConfig>()) {
      return const [];
    }
    final db = config.section<DatabaseConfig>();
    if (!db.connections.containsKey(db.defaultConnection)) {
      return [
        ConfigIssue(
          ConfigIssueLevel.error,
          'DB_CONNECTION=${db.defaultConnection} is not a configured '
          'connection (available: ${db.connections.keys.join(', ')}).',
        ),
      ];
    }
    return const [];
  }

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

    final connections = <String, ConnectionConfig>{
      'sqlite': ConnectionConfig(driver: 'sqlite', database: sqlitePath),
      'pgsql': ConnectionConfig(
        driver: 'pgsql',
        database: database ?? 'daravel',
        host: env.string('DB_HOST', '127.0.0.1'),
        port: env.integer('DB_PORT', 5432),
        username: env.maybeString('DB_USERNAME'),
        password: env.maybeString('DB_PASSWORD'),
        options: <String, Object?>{
          'pool': env.integer('DB_POOL_SIZE', 10),
          'sslmode': env.string('DB_SSLMODE', 'disable'),
          // Seconds; 0 for none. The drivers' defaults apply when unset.
          'connect_timeout': env.maybeString('DB_CONNECT_TIMEOUT'),
          'query_timeout': env.maybeString('DB_QUERY_TIMEOUT'),
        },
      ),
      // MySQL and MariaDB (Laravel 11+ names both); the driver comes from
      // package:daravel_mysql (`withDatabaseDriver`).
      for (final driver in ['mysql', 'mariadb'])
        driver: ConnectionConfig(
          driver: driver,
          database: database ?? 'daravel',
          host: env.string('DB_HOST', '127.0.0.1'),
          port: env.integer('DB_PORT', 3306),
          username: env.maybeString('DB_USERNAME'),
          password: env.maybeString('DB_PASSWORD'),
          options: <String, Object?>{
            'pool': env.integer('DB_POOL_SIZE', 10),
            'sslmode': env.string('DB_SSLMODE', 'disable'),
            'connect_timeout': env.maybeString('DB_CONNECT_TIMEOUT'),
            'query_timeout': env.maybeString('DB_QUERY_TIMEOUT'),
            'charset': env.string('DB_CHARSET', 'utf8mb4'),
            'collation': env.string('DB_COLLATION', 'utf8mb4_unicode_ci'),
            'timezone': env.maybeString('DB_TIMEZONE'),
            // Laravel's 'strict', 'modes' and 'isolation_level'.
            'strict': env.maybeString('DB_STRICT'),
            'modes': env.maybeString('DB_SQL_MODES'),
            'isolation_level': env.maybeString('DB_ISOLATION_LEVEL'),
          },
        ),
    };
    // Laravel 12 gives every connection `'url' => env('DB_URL')`.
    final url = env.maybeString('DB_URL');
    return DatabaseConfig(
      defaultConnection: defaultConnection,
      connections: url == null || url.isEmpty
          ? connections
          : {
              for (final MapEntry(:key, :value) in connections.entries)
                key: value.withUrl(url, basePath: basePath),
            },
    );
  }

  final String defaultConnection;
  final Map<String, ConnectionConfig> connections;

  /// Whether the default connection is a SQLite *file* that [isolates]
  /// isolates would share. It works (WAL, `busy_timeout`), but a writer
  /// waiting for another isolate's lock blocks its whole event loop, since
  /// SQLite calls are synchronous: for production with several isolates,
  /// PostgreSQL (or MySQL) is the database to use.
  bool sharesSqliteFile(int isolates) {
    final connection = connections[defaultConnection];
    return isolates > 1 &&
        connection?.driver == 'sqlite' &&
        connection?.database != ':memory:';
  }

  /// This configuration with [extra] connections added (or replacing ones
  /// of the same name).
  DatabaseConfig withConnections(Map<String, ConnectionConfig> extra) =>
      extra.isEmpty
      ? this
      : DatabaseConfig(
          defaultConnection: defaultConnection,
          connections: <String, ConnectionConfig>{...connections, ...extra},
        );

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
