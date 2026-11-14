import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';

/// Who answers `/broadcasting/auth` for clients of `reverb:start`
/// (`REVERB_SERVER_AUTH`).
enum ReverbAuth {
  /// The HTTP application does (Echo's `authEndpoint` points at it): the
  /// WebSocket server does not serve the route.
  app,

  /// The WebSocket server answers it too, with the application's guards.
  local,
}

/// Where `withReverb()` finds its applications (`REVERB_APPS_PROVIDER`).
enum ReverbAppsSource {
  /// `REVERB_APPS`, or the one application of `REVERB_APP_*` when empty.
  config,

  /// The `reverb_apps` table, cached.
  database,
}

/// The `reverb` configuration section (Blueprint #135 §3.3), after the
/// `servers.reverb` and `apps` of Laravel's `config/reverb.php`.
///
/// The per-application limits, `REVERB_DRAIN_SPREAD` and
/// `REVERB_PULSE_INGEST_INTERVAL` stay in [BroadcastConfig], which the
/// engine reads.
final class ReverbConfig implements ConfigSection {
  /// A configuration; the defaults are Reverb's.
  const ReverbConfig({
    this.host = '0.0.0.0',
    this.port = 8080,
    this.path = '',
    this.hostname,
    this.isolates = 1,
    this.auth = ReverbAuth.app,
    this.apps = const [],
    this.source = ReverbAppsSource.config,
    this.appsCacheTtl = const Duration(seconds: 60),
    this.metricsUrl,
  });

  /// From `REVERB_SERVER_HOST`, `REVERB_SERVER_PORT`, `REVERB_SERVER_PATH`,
  /// `REVERB_HOST`, `REVERB_SERVER_ISOLATES`, `REVERB_SERVER_AUTH`,
  /// `REVERB_APPS` (a JSON list), `REVERB_APPS_PROVIDER`,
  /// `REVERB_APPS_CACHE_TTL` and `REVERB_METRICS_URL`. A malformed
  /// `REVERB_APPS` is a [ConfigException].
  factory ReverbConfig.fromEnv(Env env) => ReverbConfig(
    host: env.string('REVERB_SERVER_HOST', '0.0.0.0'),
    port: env.integer('REVERB_SERVER_PORT', 8080),
    path: env.string('REVERB_SERVER_PATH', ''),
    hostname: env.maybeString('REVERB_HOST'),
    isolates: env.integer(
      'REVERB_SERVER_ISOLATES',
      Platform.numberOfProcessors,
    ),
    auth: _auth(env.string('REVERB_SERVER_AUTH', 'app')),
    apps: parseApps(env.string('REVERB_APPS', '')),
    source: _source(env.string('REVERB_APPS_PROVIDER', 'config')),
    appsCacheTtl: env.duration(
      'REVERB_APPS_CACHE_TTL',
      const Duration(seconds: 60),
    ),
    metricsUrl: env.maybeString('REVERB_METRICS_URL'),
  );

  static ReverbAuth _auth(String value) => switch (value) {
    'app' => ReverbAuth.app,
    'local' => ReverbAuth.local,
    _ => throw ConfigException(
      'REVERB_SERVER_AUTH is app or local, not "$value".',
    ),
  };

  static ReverbAppsSource _source(String value) => switch (value) {
    'config' => ReverbAppsSource.config,
    'database' => ReverbAppsSource.database,
    _ => throw ConfigException(
      'REVERB_APPS_PROVIDER is config or database, not "$value".',
    ),
  };

  /// The applications of a `REVERB_APPS` JSON list: entries as in Reverb's
  /// `config/reverb.php` (`app_id`, `key`, `secret`, `allowed_origins`,
  /// `max_connections`, `max_message_size`, `activity_timeout`,
  /// `rate_limiting` with `enabled`, `max_attempts`, `decay_seconds`,
  /// `terminate_on_limit`), plus `encryption_master_key` (base64). Empty
  /// for an empty [json].
  static List<BroadcastApp> parseApps(String json) {
    if (json.trim().isEmpty) {
      return const [];
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(json);
    } on FormatException catch (e) {
      throw ConfigException('REVERB_APPS is not JSON: ${e.message}.');
    }
    if (decoded is! List<Object?>) {
      throw const ConfigException('REVERB_APPS is a JSON list of apps.');
    }
    return [
      for (final (i, entry) in decoded.indexed)
        if (entry is Map<String, Object?>)
          appFromMap(entry, 'REVERB_APPS[$i]')
        else
          throw ConfigException('REVERB_APPS[$i] is not an object.'),
    ];
  }

  /// The application of one entry ([where] names it in errors): of
  /// `REVERB_APPS`, or a `reverb_apps` row with JSON columns decoded.
  static BroadcastApp appFromMap(Map<String, Object?> entry, String where) {
    String text(String name) => switch (entry[name]) {
      final String s when s.isNotEmpty => s,
      final int n => '$n',
      _ => throw ConfigException('$where needs "$name".'),
    };
    int number(String name, int fallback) => switch (entry[name]) {
      null => fallback,
      final int n => n,
      final String s when int.tryParse(s) != null => int.parse(s),
      final other => throw ConfigException(
        '$where: "$name" is a number, not $other.',
      ),
    };
    final origins = switch (entry['allowed_origins']) {
      null => const ['*'],
      final List<Object?> list => [for (final o in list) '$o'],
      final String s => s.split(',').map((o) => o.trim()).toList(),
      final other => throw ConfigException(
        '$where: "allowed_origins" is a list, not $other.',
      ),
    };
    final limit = entry['rate_limiting'];
    final BroadcastRateLimit? rateLimiting;
    if (limit is Map<String, Object?> && limit['enabled'] == true) {
      int attempt(String name, int fallback) =>
          limit[name] is int ? limit[name]! as int : fallback;
      rateLimiting = BroadcastRateLimit(
        maxAttempts: attempt('max_attempts', 60),
        decay: Duration(seconds: attempt('decay_seconds', 60)),
        terminate:
            limit['terminate_on_limit'] == true || limit['terminate'] == true,
      );
    } else {
      rateLimiting = null;
    }
    final key = entry['encryption_master_key'];
    List<int>? masterKey;
    if (key is String && key.isNotEmpty) {
      try {
        masterKey = base64.decode(key);
      } on FormatException {
        throw ConfigException('$where: "encryption_master_key" is not base64.');
      }
    }
    return BroadcastApp(
      id: text('app_id'),
      key: text('key'),
      secret: text('secret'),
      allowedOrigins: origins,
      maxConnections: number('max_connections', 0),
      maxMessageSize: number('max_message_size', 10000),
      activityTimeout: number('activity_timeout', 30),
      encryptionMasterKey: masterKey,
      rateLimiting: rateLimiting,
    );
  }

  /// The address `reverb:start` binds.
  final String host;

  /// Its port.
  final int port;

  /// The prefix of its Pusher routes (`/ws`; empty for none).
  final String path;

  /// The public host name clients reach it by (`REVERB_HOST`), for the
  /// URL `reverb:start` prints.
  final String? hostname;

  /// Its worker isolates.
  final int isolates;

  /// Who answers `/broadcasting/auth`.
  final ReverbAuth auth;

  /// The applications of `REVERB_APPS`.
  final List<BroadcastApp> apps;

  /// Where `withReverb()` finds the applications.
  final ReverbAppsSource source;

  /// How long the `database` source keeps an application it read.
  final Duration appsCacheTtl;

  /// The `/metrics` of the Reverb server the dashboard shows, when it is a
  /// process of its own (`reverb:start`); null: this process's metrics.
  final String? metricsUrl;

  @override
  String get key => 'reverb';

  /// Without secrets: the apps' public fields only.
  @override
  Map<String, Object?> toMap() => {
    'servers': {
      'reverb': {
        'host': host,
        'port': port,
        'path': path,
        'hostname': hostname,
        'isolates': isolates,
        'auth': auth.name,
      },
    },
    'apps': {
      'provider': source.name,
      'cache_ttl': appsCacheTtl.inSeconds,
      'metrics_url': _masked(metricsUrl),
      'apps': [for (final app in apps) app.toPublicMap()],
    },
  };

  /// What `ConfigValidator` reports about `REVERB_*`: unique keys and ids,
  /// secrets long enough, origin patterns that are host names, a port.
  static Iterable<ConfigIssue> check(Env env, ConfigRepository config) {
    final reverb = config.section<ReverbConfig>();
    final broadcasting = config.section<BroadcastConfig>();
    final issues = <ConfigIssue>[];
    if (reverb.port < 0 || reverb.port > 65535) {
      issues.add(
        ConfigIssue(
          ConfigIssueLevel.error,
          'REVERB_SERVER_PORT is a port, not ${reverb.port}.',
        ),
      );
    }
    if (reverb.isolates < 1) {
      issues.add(
        ConfigIssue(
          ConfigIssueLevel.error,
          'REVERB_SERVER_ISOLATES is at least 1, not ${reverb.isolates}.',
        ),
      );
    }
    final metrics = reverb.metricsUrl;
    if (metrics != null && metrics.isNotEmpty) {
      final uri = Uri.tryParse(metrics);
      if (uri == null ||
          !(uri.scheme == 'http' || uri.scheme == 'https') ||
          uri.host.isEmpty) {
        issues.add(
          const ConfigIssue(
            ConfigIssueLevel.error,
            'REVERB_METRICS_URL is the http(s) URL of the /metrics of a Reverb server.',
          ),
        );
      }
    }
    if (reverb.path.isNotEmpty && !reverb.path.startsWith('/')) {
      issues.add(
        ConfigIssue(
          ConfigIssueLevel.error,
          'REVERB_SERVER_PATH starts with /, as "/${reverb.path}".',
        ),
      );
    }
    final ids = <String>{};
    final keys = <String>{};
    for (final app in reverb.apps) {
      if (!ids.add(app.id)) {
        issues.add(
          ConfigIssue(
            ConfigIssueLevel.error,
            'REVERB_APPS: app_id "${app.id}" is used twice.',
          ),
        );
      }
      if (!keys.add(app.key)) {
        issues.add(
          ConfigIssue(
            ConfigIssueLevel.error,
            'REVERB_APPS: key "${app.key}" is used twice.',
          ),
        );
      }
      issues.addAll(appIssues(app, 'REVERB_APPS app ${app.id}'));
      if (app.maxMessageSize > broadcasting.maxMessageSize) {
        issues.add(
          ConfigIssue(
            ConfigIssueLevel.warning,
            'REVERB_APPS app ${app.id}: max_message_size '
            '${app.maxMessageSize} is above REVERB_APP_MAX_MESSAGE_SIZE '
            '(${broadcasting.maxMessageSize}), which bounds every frame.',
          ),
        );
      }
    }
    return issues;
  }

  /// What is wrong with [app] ([where] names it): a secret under 32 bytes
  /// (a warning: Laravel's `reverb:install` makes 20 characters), origin
  /// patterns that are not host names.
  static Iterable<ConfigIssue> appIssues(BroadcastApp app, String where) => [
    if (utf8.encode(app.secret).length < 32)
      ConfigIssue(
        ConfigIssueLevel.warning,
        '$where: its secret is shorter than 32 bytes; anyone who guesses '
        'it can sign broadcasts.',
      ),
    for (final origin in app.allowedOrigins)
      if (!_origin.hasMatch(origin))
        ConfigIssue(
          ConfigIssueLevel.error,
          '$where: allowed origin "$origin" is a host name pattern '
          '(example.com, *.example.com or *), without a scheme or path.',
        ),
  ];

  static final RegExp _origin = RegExp(
    r'^(\*|(\*\.)?[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*(:\d+)?)$',
  );
}

/// [url] with its password and sensitive query values masked
/// (`http://user:***@host`; `redactUrl`, which needs no valid URL: a value
/// `Uri.tryParse` refused used to be shown whole), for `toMap`.
String? _masked(String? url) =>
    url == null ? null : redactUrl(url, loneUserIsPassword: true);
