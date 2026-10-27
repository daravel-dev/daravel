import 'dart:io';

import 'package:daravel/daravel.dart';

import 'queue.dart';
import 'serializer.dart';

/// How a connection finds its server (`REDIS_MODE`).
enum RedisMode {
  /// One server at [RedisConnectionConfig.host].
  standalone,

  /// The master that Sentinel reports for
  /// [RedisConnectionConfig.sentinelService], found again after a
  /// failover.
  sentinel,

  /// A Redis Cluster: each key goes to the master of its hash slot.
  cluster,
}

/// A server's address.
typedef RedisNode = ({String host, int port});

/// One Redis (or Valkey) server and database, or the Sentinels or Cluster
/// nodes that lead to them ([mode]).
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
    this.mode = RedisMode.standalone,
    this.nodes = const [],
    this.sentinelService = 'mymaster',
    this.sentinelUsername,
    this.sentinelPassword,
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
    final sentinel = (
      username: env.maybeString('REDIS_SENTINEL_USERNAME'),
      password: env.maybeString('REDIS_SENTINEL_PASSWORD'),
    );
    final url = env.maybeString('REDIS_URL');
    if (url != null && url.isNotEmpty) {
      final parsed = RedisConnectionConfig.fromUrl(url);
      return parsed.copyWith(
        database: parsed.mode == RedisMode.cluster
            ? 0
            : database ?? parsed.database,
        commandTimeout: timeouts.command,
        connectTimeout: timeouts.connect,
        maxInFlight: timeouts.inFlight,
        sentinelUsername: sentinel.username,
        sentinelPassword: sentinel.password,
      );
    }
    final mode = switch (env.string('REDIS_MODE', 'standalone')) {
      'standalone' => RedisMode.standalone,
      'sentinel' => RedisMode.sentinel,
      'cluster' => RedisMode.cluster,
      final other => throw ConfigException(
        'REDIS_MODE must be standalone, sentinel or cluster (got $other).',
      ),
    };
    final host = env.string('REDIS_HOST', '127.0.0.1');
    final port = env.integer('REDIS_PORT', 6379);
    final nodes = switch (env.maybeString('REDIS_NODES')) {
      final String list when list.trim().isNotEmpty => _nodes(
        list,
        mode == RedisMode.sentinel ? 26379 : 6379,
      ),
      _ =>
        mode == RedisMode.standalone
            ? const <RedisNode>[]
            : [(host: host, port: port)],
    };
    return RedisConnectionConfig(
      host: nodes.isEmpty ? host : nodes.first.host,
      port: nodes.isEmpty ? port : nodes.first.port,
      username: env.maybeString('REDIS_USERNAME'),
      password: env.maybeString('REDIS_PASSWORD'),
      database: mode == RedisMode.cluster
          ? 0
          : database ?? env.integer('REDIS_DB', 0),
      tls: env.boolean('REDIS_TLS', false),
      commandTimeout: timeouts.command,
      connectTimeout: timeouts.connect,
      maxInFlight: timeouts.inFlight,
      mode: mode,
      nodes: nodes,
      sentinelService: env.string('REDIS_SENTINEL_SERVICE', 'mymaster'),
      sentinelUsername: sentinel.username,
      sentinelPassword: sentinel.password,
    );
  }

  /// `host:port,host:port` (`[::1]:6379` for IPv6).
  static List<RedisNode> _nodes(String list, int defaultPort) => [
    for (final part in list.split(','))
      if (part.trim() case final String node when node.isNotEmpty)
        switch (RegExp(r'^\[([^\]]+)\](?::(\d+))?$|^([^:]+)(?::(\d+))?$')
            .firstMatch(node)) {
          final RegExpMatch m => (
            host: m[1] ?? m[3]!,
            port: int.parse(m[2] ?? m[4] ?? '$defaultPort'),
          ),
          null => throw ConfigException('Invalid Redis node [$node].'),
        },
  ];

  /// `redis://[user:password@]host[:port][/database]`; `rediss://` turns
  /// TLS on. Sentinel and Cluster list their nodes:
  /// `redis+sentinel://[user:password@]host:26379,host:26379/service[/database]`
  /// and `redis+cluster://[user:password@]host:6379,host:6379`, the
  /// credentials being the data servers' (`REDIS_SENTINEL_PASSWORD` is the
  /// Sentinels').
  factory RedisConnectionConfig.fromUrl(String url) {
    final scheme = url.contains('://')
        ? url.substring(0, url.indexOf('://'))
        : '';
    if (scheme.endsWith('+sentinel') || scheme.endsWith('+cluster')) {
      return RedisConnectionConfig._multi(url, scheme);
    }
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

  factory RedisConnectionConfig._multi(String url, String scheme) {
    final sentinel = scheme.endsWith('+sentinel');
    if (scheme != 'redis+sentinel' &&
        scheme != 'rediss+sentinel' &&
        scheme != 'redis+cluster' &&
        scheme != 'rediss+cluster') {
      throw ConfigException('Unsupported Redis URL scheme [$scheme].');
    }
    final rest = url.substring(scheme.length + 3);
    final slash = rest.indexOf('/');
    final authority = slash < 0 ? rest : rest.substring(0, slash);
    final path = slash < 0 ? '' : rest.substring(slash + 1);
    final at = authority.lastIndexOf('@');
    final user = at < 0
        ? const <String>[]
        : authority.substring(0, at).split(':');
    final nodes = _nodes(
      at < 0 ? authority : authority.substring(at + 1),
      sentinel ? 26379 : 6379,
    );
    if (nodes.isEmpty) {
      throw ConfigException('REDIS_URL lists no $scheme nodes.');
    }
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    if (sentinel && segments.isEmpty) {
      throw const ConfigException(
        'A redis+sentinel:// URL names its service: '
        'redis+sentinel://host:26379/mymaster.',
      );
    }
    return RedisConnectionConfig(
      host: nodes.first.host,
      port: nodes.first.port,
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
      database: sentinel && segments.length > 1 ? int.parse(segments[1]) : 0,
      tls: scheme.startsWith('rediss'),
      mode: sentinel ? RedisMode.sentinel : RedisMode.cluster,
      nodes: nodes,
      sentinelService: sentinel
          ? Uri.decodeComponent(segments.first)
          : 'mymaster',
    );
  }

  /// This configuration with the given fields replaced.
  RedisConnectionConfig copyWith({
    int? database,
    Duration? commandTimeout,
    Duration? connectTimeout,
    int? maxInFlight,
    String? sentinelUsername,
    String? sentinelPassword,
  }) => RedisConnectionConfig(
    host: host,
    port: port,
    username: username,
    password: password,
    database: database ?? this.database,
    tls: tls,
    commandTimeout: commandTimeout ?? this.commandTimeout,
    connectTimeout: connectTimeout ?? this.connectTimeout,
    maxInFlight: maxInFlight ?? this.maxInFlight,
    mode: mode,
    nodes: nodes,
    sentinelService: sentinelService,
    sentinelUsername: sentinelUsername ?? this.sentinelUsername,
    sentinelPassword: sentinelPassword ?? this.sentinelPassword,
  );

  /// One server of a Sentinel or Cluster setup ([sentinel]: a Sentinel
  /// itself, with the Sentinels' credentials), reached directly.
  RedisConnectionConfig node(String host, int port, {bool sentinel = false}) =>
      RedisConnectionConfig(
        host: host,
        port: port,
        username: sentinel ? sentinelUsername : username,
        password: sentinel ? sentinelPassword : password,
        database: sentinel || mode == RedisMode.cluster ? 0 : database,
        tls: tls,
        commandTimeout: commandTimeout,
        connectTimeout: connectTimeout,
        maxInFlight: maxInFlight,
      );

  final String host;
  final int port;
  final String? username;
  final String? password;
  final int database;
  final bool tls;

  final RedisMode mode;

  /// The Sentinels ([RedisMode.sentinel]) or the Cluster nodes to start
  /// from ([RedisMode.cluster]): `REDIS_NODES`, or the URL's hosts.
  final List<RedisNode> nodes;

  /// The master's name at the Sentinels (`REDIS_SENTINEL_SERVICE`).
  final String sentinelService;

  /// The Sentinels' own credentials (`REDIS_SENTINEL_USERNAME`,
  /// `REDIS_SENTINEL_PASSWORD`), when they require one.
  final String? sentinelUsername;
  final String? sentinelPassword;

  /// The longest a command may wait for its reply (`REDIS_COMMAND_TIMEOUT`).
  final Duration commandTimeout;
  final Duration connectTimeout;

  /// Commands that may wait for replies on one connection
  /// (`REDIS_MAX_IN_FLIGHT`).
  final int maxInFlight;

  /// The connection without its password, for logs and errors.
  String get redacted {
    final credentials =
        '${username == null ? '' : '$username:'}'
        '${password == null ? '' : '********@'}';
    final scheme = tls ? 'rediss' : 'redis';
    final hosts = [for (final n in nodes) '${n.host}:${n.port}'].join(',');
    return switch (mode) {
      RedisMode.standalone => '$scheme://$credentials$host:$port/$database',
      RedisMode.sentinel =>
        '$scheme+sentinel://$credentials$hosts/$sentinelService/$database',
      RedisMode.cluster => '$scheme+cluster://$credentials$hosts',
    };
  }

  /// Whether every server this connection reaches is on this machine or a
  /// private network: no TLS needed.
  bool get isPrivateHost =>
      nodes.isEmpty ? _isPrivate(host) : nodes.every((n) => _isPrivate(n.host));

  static bool _isPrivate(String host) {
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
    'mode': mode.name,
    if (nodes.isNotEmpty)
      'nodes': [for (final n in nodes) '${n.host}:${n.port}'],
    if (mode == RedisMode.sentinel) 'sentinel_service': sentinelService,
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
    this.queueEngine = RedisQueueEngine.list,
    this.serializer = RedisSerializer.json,
    this.tieredMaxKeys = 10000,
    this.tieredTtl = const Duration(seconds: 60),
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
      queueEngine: _choice(
        env,
        'QUEUE_REDIS_ENGINE',
        RedisQueueEngine.values,
        RedisQueueEngine.list,
      ),
      serializer: _choice(
        env,
        'REDIS_SERIALIZER',
        RedisSerializer.values,
        RedisSerializer.json,
      ),
      tieredMaxKeys: env.integer('REDIS_TIERED_MAX_KEYS', 10000),
      tieredTtl: env.duration('REDIS_TIERED_TTL', const Duration(seconds: 60)),
    );
  }

  static T _choice<T extends Enum>(
    Env env,
    String name,
    List<T> values,
    T fallback,
  ) {
    final value = env.string(name, fallback.name);
    for (final option in values) {
      if (option.name == value) {
        return option;
      }
    }
    throw ConfigException(
      '$name must be ${values.map((v) => v.name).join(' or ')} (got $value).',
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

  /// How queues keep their jobs (`QUEUE_REDIS_ENGINE`: `list`, `stream`).
  final RedisQueueEngine queueEngine;

  /// How cached values that are not numbers are written
  /// (`REDIS_SERIALIZER`: `json`, or `php` to share them with Laravel).
  final RedisSerializer serializer;

  /// The `tiered` store's L1: entries per isolate (`REDIS_TIERED_MAX_KEYS`)
  /// and their longest life (`REDIS_TIERED_TTL`).
  final int tieredMaxKeys;
  final Duration tieredTtl;

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
    'queue_engine': queueEngine.name,
    'serializer': serializer.name,
    'tiered_max_keys': tieredMaxKeys,
    'tiered_ttl_ms': tieredTtl.inMilliseconds,
    'connections': {
      for (final MapEntry(key: name, value: connection) in connections.entries)
        name: connection.toMap(),
    },
  };
}
