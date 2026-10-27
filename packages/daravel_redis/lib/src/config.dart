import 'dart:io';

import 'package:daravel/daravel.dart';

/// One Redis (or Valkey) server and database.
final class RedisConnectionConfig {
  const RedisConnectionConfig({
    this.host = '127.0.0.1',
    this.port = 6379,
    this.username,
    this.password,
    this.database = 0,
    this.tls = false,
    this.commandTimeout = const Duration(seconds: 1),
    this.connectTimeout = const Duration(seconds: 2),
    this.maxInFlight = 1024,
  });

  /// `REDIS_URL` (`redis://user:pass@host:port/db`, `rediss://` for TLS),
  /// else `REDIS_HOST`, `REDIS_PORT`, `REDIS_USERNAME`, `REDIS_PASSWORD`
  /// and [database] (`REDIS_DB`), as Laravel's `config/database.php` reads
  /// them.
  factory RedisConnectionConfig.fromEnv(Env env, {int? database}) {
    final timeouts = (
      command: env.duration(
        'REDIS_COMMAND_TIMEOUT',
        const Duration(seconds: 1),
      ),
      connect: env.duration(
        'REDIS_CONNECT_TIMEOUT',
        const Duration(seconds: 2),
      ),
      inFlight: env.integer('REDIS_MAX_IN_FLIGHT', 1024),
    );
    final url = env.maybeString('REDIS_URL');
    if (url != null && url.isNotEmpty) {
      final parsed = RedisConnectionConfig.fromUrl(url);
      return RedisConnectionConfig(
        host: parsed.host,
        port: parsed.port,
        username: parsed.username,
        password: parsed.password,
        database: database ?? parsed.database,
        tls: parsed.tls,
        commandTimeout: timeouts.command,
        connectTimeout: timeouts.connect,
        maxInFlight: timeouts.inFlight,
      );
    }
    return RedisConnectionConfig(
      host: env.string('REDIS_HOST', '127.0.0.1'),
      port: env.integer('REDIS_PORT', 6379),
      username: env.maybeString('REDIS_USERNAME'),
      password: env.maybeString('REDIS_PASSWORD'),
      database: database ?? env.integer('REDIS_DB', 0),
      tls: env.boolean('REDIS_TLS', false),
      commandTimeout: timeouts.command,
      connectTimeout: timeouts.connect,
      maxInFlight: timeouts.inFlight,
    );
  }

  /// `redis://[user:password@]host[:port][/database]`; `rediss://` turns
  /// TLS on.
  factory RedisConnectionConfig.fromUrl(String url) {
    final uri = Uri.parse(url);
    if (uri.scheme != 'redis' && uri.scheme != 'rediss') {
      throw ConfigException(
        'REDIS_URL must start with redis:// or rediss:// (got ${uri.scheme}).',
      );
    }
    final user = uri.userInfo.split(':');
    final path = uri.path.replaceFirst('/', '');
    return RedisConnectionConfig(
      host: uri.host.isEmpty ? '127.0.0.1' : uri.host,
      port: uri.hasPort ? uri.port : 6379,
      username: user.length > 1 && user.first.isNotEmpty
          ? Uri.decodeComponent(user.first)
          : null,
      password: switch (user) {
        [_, final String password] => Uri.decodeComponent(password),
        [final String password] when password.isNotEmpty => Uri.decodeComponent(
          password,
        ),
        _ => null,
      },
      database: path.isEmpty ? 0 : int.parse(path),
      tls: uri.scheme == 'rediss',
    );
  }

  final String host;
  final int port;
  final String? username;
  final String? password;
  final int database;
  final bool tls;

  /// The longest a command may wait for its reply (`REDIS_COMMAND_TIMEOUT`).
  final Duration commandTimeout;
  final Duration connectTimeout;

  /// Commands that may wait for replies on one connection
  /// (`REDIS_MAX_IN_FLIGHT`).
  final int maxInFlight;

  /// The connection without its password, for logs and errors.
  String get redacted =>
      '${tls ? 'rediss' : 'redis'}://'
      '${username == null ? '' : '$username:'}'
      '${password == null ? '' : '********@'}$host:$port/$database';

  /// Whether [host] is this machine or a private network: no TLS needed.
  bool get isPrivateHost {
    if (host == 'localhost' || !host.contains('.')) {
      return true; // a loopback name or a container / service name
    }
    final address = InternetAddress.tryParse(host);
    if (address == null) {
      return host.endsWith('.local') || host.endsWith('.internal');
    }
    if (address.isLoopback || address.isLinkLocal) {
      return true;
    }
    final bytes = address.rawAddress;
    return address.type == InternetAddressType.IPv4 &&
        (bytes[0] == 10 ||
            (bytes[0] == 172 && bytes[1] >= 16 && bytes[1] < 32) ||
            (bytes[0] == 192 && bytes[1] == 168));
  }

  Map<String, Object?> toMap() => {
    'host': host,
    'port': port,
    'username': username,
    'password': password == null ? null : '********',
    'database': database,
    'tls': tls,
    'command_timeout_ms': commandTimeout.inMilliseconds,
  };

  @override
  String toString() => redacted;
}

/// `config/database.php`'s `redis` section: the `default` connection
/// (queues, broadcasting, the facade) and the `cache` one (`REDIS_CACHE_DB`,
/// 1 by default, so `cache:clear` never touches queued jobs).
final class RedisConfig implements ConfigSection {
  const RedisConfig({
    this.connections = const {
      'default': RedisConnectionConfig(),
      'cache': RedisConnectionConfig(database: 1),
    },
    this.prefix = 'daravel-database-',
    this.queueNamespace = 'daravel',
    this.lockConnection = 'default',
  });

  factory RedisConfig.fromEnv(Env env) {
    final app = env.string('APP_NAME', 'daravel');
    return RedisConfig(
      connections: {
        'default': RedisConnectionConfig.fromEnv(env),
        'cache': RedisConnectionConfig.fromEnv(
          env,
          database: env.integer('REDIS_CACHE_DB', 1),
        ),
      },
      // Laravel 12's default: Str::slug(APP_NAME).'-database-'.
      prefix: env.string(
        'REDIS_PREFIX',
        '${app.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-+|-+$'), '')}-database-',
      ),
      queueNamespace: env.string('QUEUE_REDIS_NAMESPACE', 'daravel'),
      lockConnection: env.string('REDIS_CACHE_LOCK_CONNECTION', 'default'),
    );
  }

  final Map<String, RedisConnectionConfig> connections;

  /// Put before every key (`REDIS_PREFIX`, Laravel's `<app>-database-`).
  final String prefix;

  /// Where cache locks live (`REDIS_CACHE_LOCK_CONNECTION`): the `default`
  /// connection, as Laravel's `lock_connection`, so both see one lock.
  final String lockConnection;

  /// The queues' own part of the key space (`QUEUE_REDIS_NAMESPACE`), apart
  /// from Laravel's `queues:` (whose workers could not run Daravel jobs).
  final String queueNamespace;

  RedisConnectionConfig connection([String name = 'default']) =>
      connections[name] ??
      (throw ConfigException('Redis connection [$name] is not configured.'));

  /// Warns when a connection to a public host goes without TLS.
  static Iterable<ConfigIssue> check(Env env, ConfigRepository config) {
    final redis = config.section<RedisConfig>();
    return [
      for (final MapEntry(key: name, value: connection)
          in redis.connections.entries)
        if (!connection.tls && !connection.isPrivateHost)
          ConfigIssue(
            ConfigIssueLevel.warning,
            'Redis connection [$name] reaches ${connection.host} without TLS; '
            'use rediss:// or REDIS_TLS=true outside a private network.',
          ),
    ];
  }

  @override
  String get key => 'redis';

  @override
  Map<String, Object?> toMap() => {
    'prefix': prefix,
    'queue_namespace': queueNamespace,
    'lock_connection': lockConnection,
    'connections': {
      for (final MapEntry(key: name, value: connection) in connections.entries)
        name: connection.toMap(),
    },
  };
}
