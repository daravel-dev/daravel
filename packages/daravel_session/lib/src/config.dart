import 'package:daravel/daravel.dart';

/// `SESSION_*` settings (Laravel's `config/session.php`).
final class SessionConfig implements ConfigSection {
  const SessionConfig({
    this.driver = 'file',
    this.lifetime = const Duration(minutes: 120),
    this.expireOnClose = false,
    this.files = 'storage/framework/sessions',
    this.connection,
    this.table = 'sessions',
    this.cookie = 'daravel_session',
    this.path = '/',
    this.domain,
    this.secure = false,
    this.httpOnly = true,
    this.sameSite = 'lax',
    this.lottery = (2, 100),
  });

  /// Reads the `SESSION_*` variables with Laravel's defaults; the cookie
  /// name is `<app name as a slug>_session`, as Laravel derives it.
  factory SessionConfig.fromEnv(Env env) {
    final appName = env.string('APP_NAME', 'daravel');
    final sameSite = env.string('SESSION_SAME_SITE', 'lax');
    return SessionConfig(
      driver: env.string('SESSION_DRIVER', 'file'),
      lifetime: Duration(minutes: env.integer('SESSION_LIFETIME', 120)),
      expireOnClose: env.boolean('SESSION_EXPIRE_ON_CLOSE', false),
      files: env.string('SESSION_FILES', 'storage/framework/sessions'),
      connection: env.maybeString('SESSION_CONNECTION'),
      table: env.string('SESSION_TABLE', 'sessions'),
      cookie: env.string('SESSION_COOKIE', '${slug(appName)}_session'),
      path: env.string('SESSION_PATH', '/'),
      domain: switch (env.maybeString('SESSION_DOMAIN')) {
        null || '' => null,
        final domain => domain,
      },
      secure: env.boolean('SESSION_SECURE_COOKIE', false),
      httpOnly: env.boolean('SESSION_HTTP_ONLY', true),
      sameSite: sameSite == 'null' || sameSite.isEmpty ? null : sameSite,
    );
  }

  /// `file`, `database`, `array` (tests) or a driver registered with
  /// [SessionManager.extend].
  final String driver;
  final Duration lifetime;
  final bool expireOnClose;

  /// Directory of the `file` driver, relative to the application's base
  /// path.
  final String files;

  /// Database connection of the `database` driver (default connection
  /// when `null`).
  final String? connection;
  final String table;
  final String cookie;
  final String path;
  final String? domain;
  final bool secure;
  final bool httpOnly;

  /// `lax`, `strict`, `none` or `null` (no attribute).
  final String? sameSite;

  /// Garbage-collection odds, `(2, 100)`: 2 requests in 100 sweep expired
  /// sessions.
  final (int, int) lottery;

  /// Laravel's `Str::slug($name, '_')`: lower case, letters and digits,
  /// runs of anything else as one `_`.
  static String slug(String value) => value
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  @override
  String get key => 'session';

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'driver': driver,
    'lifetime': lifetime.inMinutes,
    'expire_on_close': expireOnClose,
    'files': files,
    'connection': connection,
    'table': table,
    'cookie': cookie,
    'path': path,
    'domain': domain,
    'secure': secure,
    'http_only': httpOnly,
    'same_site': sameSite,
    'lottery': [lottery.$1, lottery.$2],
  };

  /// Rejects an unknown `SESSION_SAME_SITE` and a non-positive lifetime.
  static Iterable<ConfigIssue> check(Env env, ConfigRepository config) sync* {
    final session = config.section<SessionConfig>();
    if (session.sameSite case final value?
        when !const {'lax', 'strict', 'none'}.contains(value)) {
      yield ConfigIssue(
        ConfigIssueLevel.error,
        'SESSION_SAME_SITE=$value is not lax, strict, none or null.',
      );
    }
    if (session.lifetime <= Duration.zero) {
      yield const ConfigIssue(
        ConfigIssueLevel.error,
        'SESSION_LIFETIME must be a positive number of minutes.',
      );
    }
    if (session.sameSite == 'none' && !session.secure) {
      yield const ConfigIssue(
        ConfigIssueLevel.warning,
        'SESSION_SAME_SITE=none needs SESSION_SECURE_COOKIE=true: browsers '
        'drop a SameSite=None cookie without Secure.',
      );
    }
  }
}
