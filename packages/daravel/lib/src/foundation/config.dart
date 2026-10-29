import 'container.dart';
import 'env.dart';
import 'exceptions.dart';

/// A typed configuration section (ADR-007). Each section is registered once
/// and projected into the dot-notation map used by `Config.get('app.name')`.
abstract interface class ConfigSection {
  /// Top-level key of the section, e.g. `app` or `database`.
  String get key;

  /// Plain-map projection used for dot-notation access.
  Map<String, Object?> toMap();
}

/// Holds typed configuration sections and their dot-notation projection.
///
/// The repository is frozen once the application has booted: mutations after
/// that point throw, which prevents cross-request state leaks (principle P3).
final class ConfigRepository {
  final Map<String, Object?> _items = <String, Object?>{};
  final Map<Type, ConfigSection> _sections = <Type, ConfigSection>{};
  bool _frozen = false;

  /// Whether the repository is frozen (read-only).
  bool get frozen => _frozen;

  /// Registers a typed [section] and merges its map projection.
  void register<T extends ConfigSection>(T section) {
    _ensureMutable();
    _sections[T] = section;
    _items[section.key] = section.toMap();
  }

  /// Returns the typed section [T]; throws [ConfigException] if missing.
  T section<T extends ConfigSection>() {
    final section = _sections[T];
    if (section == null) {
      throw ConfigException('Config section [$T] is not registered.');
    }
    return section as T;
  }

  /// Whether a typed section [T] is registered.
  bool hasSection<T extends ConfigSection>() => _sections.containsKey(T);

  /// Dot-notation lookup. Returns [fallback] when the key is missing; throws
  /// [ConfigException] when the key is missing without fallback (for a
  /// non-nullable [T]) or when the value has the wrong type.
  T get<T>(String key, [T? fallback]) {
    final value = _lookup(key);
    if (value == null) {
      if (fallback != null) {
        return fallback;
      }
      if (null is T) {
        return null as T;
      }
      throw ConfigException('Config key [$key] is not defined.');
    }
    if (value is T) {
      return value as T;
    }
    throw ConfigException(
      'Config key [$key] has type ${value.runtimeType}, expected $T.',
    );
  }

  /// Whether [key] resolves to a non-null value.
  bool has(String key) => _lookup(key) != null;

  /// Sets a dot-notation [key] (only before the repository is frozen).
  void set(String key, Object? value) {
    _ensureMutable();
    final segments = key.split('.');
    var target = _items;
    for (var i = 0; i < segments.length - 1; i++) {
      final segment = segments[i];
      final next = target[segment];
      if (next is Map<String, Object?>) {
        target = next;
      } else {
        final created = <String, Object?>{};
        target[segment] = created;
        target = created;
      }
    }
    target[segments.last] = value;
  }

  /// Freezes the repository; further [register]/[set] calls throw.
  void freeze() => _frozen = true;

  /// A read-only view of the dot-notation projection.
  Map<String, Object?> all() => Map.unmodifiable(_items);

  Object? _lookup(String key) {
    Object? current = _items;
    for (final segment in key.split('.')) {
      if (current is Map<String, Object?>) {
        current = current[segment];
      } else if (current is Map<Object?, Object?>) {
        current = current[segment];
      } else {
        return null;
      }
    }
    return current;
  }

  void _ensureMutable() {
    if (_frozen) {
      throw ConfigException(
        'The configuration repository is frozen after boot; '
        'use Config.fake() in tests or configure before boot.',
      );
    }
  }
}

/// Core application settings (`config/app.php` parity).
final class AppConfig implements ConfigSection {
  const AppConfig({
    required this.name,
    required this.env,
    required this.debug,
    required this.url,
    required this.timezone,
    required this.locale,
    this.laravelCompat = defaultLaravelCompat,
  });

  /// Reads `APP_*` variables with Laravel-compatible defaults.
  factory AppConfig.fromEnv(Env env) => AppConfig(
    name: env.string('APP_NAME', 'Daravel'),
    env: env.string('APP_ENV', 'production'),
    debug: env.boolean('APP_DEBUG', false),
    url: env.string('APP_URL', 'http://localhost:8000'),
    timezone: env.string('APP_TIMEZONE', 'UTC'),
    locale: env.string('APP_LOCALE', 'en'),
    laravelCompat: parseLaravelCompat(
      env.maybeString('COMPAT_LARAVEL_VERSION'),
    ),
  );

  final String name;
  final String env;
  final bool debug;
  final String url;
  final String timezone;
  final String locale;

  /// The Laravel major version whose wire formats the application answers
  /// with (`COMPAT_LARAVEL_VERSION`, 8 to 13, default 12). 10 to 13 share
  /// them. 9 uses the older validation messages (`The email must be ...`);
  /// 8 also answers `The given data was invalid.` for every 422, an empty
  /// 404 message and `... not supported for this route.` for a 405.
  final int laravelCompat;

  /// The default of [laravelCompat]: the Laravel the conformance suite pins.
  static const int defaultLaravelCompat = 12;

  /// Parses `COMPAT_LARAVEL_VERSION`: a major version (`8`), optionally
  /// as `8.x` or a full version (`8.83.27`).
  static int parseLaravelCompat(String? value) {
    if (value == null || value.trim().isEmpty) {
      return defaultLaravelCompat;
    }
    final major = int.tryParse(value.trim().split('.').first);
    if (major == null || major < 8 || major > 13) {
      throw ConfigException(
        'COMPAT_LARAVEL_VERSION=$value is not supported: use 8 to 13.',
      );
    }
    return major;
  }

  bool get isProduction => env == 'production';
  bool get isTesting => env == 'testing';
  bool get isLocal => env == 'local';

  @override
  String get key => 'app';

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'name': name,
    'env': env,
    'debug': debug,
    'url': url,
    'timezone': timezone,
    'locale': locale,
    'laravel_compat': laravelCompat,
  };
}

/// The `COMPAT_LARAVEL_VERSION` of the active application, or
/// [AppConfig.defaultLaravelCompat] outside one (a unit test of a
/// validator, a script).
int currentLaravelCompat() {
  final config = Container.currentOrNull?.tryMake<ConfigRepository>();
  if (config == null) {
    return AppConfig.defaultLaravelCompat;
  }
  try {
    return config.section<AppConfig>().laravelCompat;
  } on ConfigException {
    return AppConfig.defaultLaravelCompat;
  }
}
