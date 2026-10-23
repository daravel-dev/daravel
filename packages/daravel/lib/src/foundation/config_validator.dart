import 'dart:convert';

import '../database/database_config.dart';
import 'config.dart';
import 'env.dart';
import 'exceptions.dart';

/// Severity of a [ConfigIssue].
enum ConfigIssueLevel { warning, error }

/// A problem found by [ConfigValidator].
final class ConfigIssue {
  const ConfigIssue(this.level, this.message);

  final ConfigIssueLevel level;
  final String message;

  bool get isError => level == ConfigIssueLevel.error;

  @override
  String toString() => '${level.name.toUpperCase()}: $message';
}

/// A reusable configuration check.
typedef ConfigCheck =
    Iterable<ConfigIssue> Function(Env env, ConfigRepository config);

/// Validates configuration at boot (BLUEPRINT_V2 §5.3 step 3, §9.2).
///
/// Errors abort the boot with a [ConfigException] listing every problem;
/// warnings are logged. Applications can add their own checks through
/// `ApplicationBuilder.withConfigCheck`.
final class ConfigValidator {
  ConfigValidator({List<ConfigCheck> extraChecks = const []})
    : _checks = [...defaultChecks, ...extraChecks];

  final List<ConfigCheck> _checks;

  /// The framework's built-in checks.
  static final List<ConfigCheck> defaultChecks = [
    _debugInProduction,
    _appKey,
    _databaseDefault,
  ];

  /// Runs every check and returns all issues (errors first).
  List<ConfigIssue> validate(Env env, ConfigRepository config) {
    final issues = <ConfigIssue>[
      for (final check in _checks) ...check(env, config),
    ];
    issues.sort((a, b) => b.level.index.compareTo(a.level.index));
    return issues;
  }

  /// Runs [validate] and throws a [ConfigException] when any error exists.
  List<ConfigIssue> validateOrThrow(Env env, ConfigRepository config) {
    final issues = validate(env, config);
    final errors = issues.where((issue) => issue.isError).toList();
    if (errors.isNotEmpty) {
      throw ConfigException(
        'Invalid configuration:\n${errors.map((e) => '  - ${e.message}').join('\n')}',
      );
    }
    return issues;
  }

  static Iterable<ConfigIssue> _debugInProduction(
    Env env,
    ConfigRepository config,
  ) {
    final app = config.section<AppConfig>();
    if (!app.isProduction || !app.debug) {
      return const [];
    }
    if (env.boolean('APP_ALLOW_DEBUG_IN_PRODUCTION', false)) {
      return const [
        ConfigIssue(
          ConfigIssueLevel.warning,
          'APP_DEBUG=true in production is allowed by '
          'APP_ALLOW_DEBUG_IN_PRODUCTION; error responses will include stack traces.',
        ),
      ];
    }
    return const [
      ConfigIssue(
        ConfigIssueLevel.error,
        'APP_DEBUG=true while APP_ENV=production. Set APP_DEBUG=false, or set '
        'APP_ALLOW_DEBUG_IN_PRODUCTION=true to override explicitly.',
      ),
    ];
  }

  static Iterable<ConfigIssue> _appKey(Env env, ConfigRepository config) {
    final key = env.maybeString('APP_KEY');
    if (key == null || key.isEmpty) {
      return const [
        ConfigIssue(
          ConfigIssueLevel.warning,
          'APP_KEY is not set. Run `dartisan key:generate` before using '
          'encryption, signed URLs or tokens.',
        ),
      ];
    }
    const prefix = 'base64:';
    if (!key.startsWith(prefix)) {
      return const [
        ConfigIssue(
          ConfigIssueLevel.error,
          'APP_KEY must be a base64 encoded 32-byte key in the form '
          '"base64:..." (run `dartisan key:generate`).',
        ),
      ];
    }
    try {
      final bytes = base64.decode(key.substring(prefix.length));
      if (bytes.length != 32) {
        return [
          ConfigIssue(
            ConfigIssueLevel.error,
            'APP_KEY must decode to 32 bytes, got ${bytes.length}.',
          ),
        ];
      }
    } on FormatException {
      return const [
        ConfigIssue(ConfigIssueLevel.error, 'APP_KEY is not valid base64.'),
      ];
    }
    return const [];
  }

  static Iterable<ConfigIssue> _databaseDefault(
    Env env,
    ConfigRepository config,
  ) {
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
}
