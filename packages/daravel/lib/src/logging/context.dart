import '../foundation/container.dart';

/// Data of one request, job or command (Laravel 11's `Context`).
final class ContextRepository {
  final Map<String, Object?> data = <String, Object?>{};
  final Map<String, Object?> hidden = <String, Object?>{};

  /// JSON-safe snapshot carried in queued job payloads (`null` when empty).
  Map<String, Object?>? dehydrate() => data.isEmpty && hidden.isEmpty
      ? null
      : {
          'data': {...data},
          'hidden': {...hidden},
        };

  void hydrate(Map<String, Object?>? snapshot) {
    if (snapshot == null) {
      return;
    }
    data.addAll(_map(snapshot['data']));
    hidden.addAll(_map(snapshot['hidden']));
  }

  static Map<String, Object?> _map(Object? value) => switch (value) {
    final Map<Object?, Object?> map => {
      for (final MapEntry(:key, :value) in map.entries) '$key': value,
    },
    _ => const {},
  };
}

/// Laravel 11's `Context`: data that belongs to the current request, job or
/// command, added to every log record and carried into the jobs it
/// dispatches:
///
/// ```dart
/// Context.add('tenant_id', tenant.id);   // in a middleware
/// Context.addHidden('api_token', token); // carried, never logged
/// Context.get<int>('tenant_id');         // later, or inside the queued job
/// ```
///
/// Values must be JSON-encodable, like job data. Outside any scope the data
/// belongs to the isolate.
abstract final class Context {
  static final ContextRepository _isolate = ContextRepository();

  /// The repository of the current scope (created on first use).
  static ContextRepository get current {
    final Scope? scope;
    try {
      scope = Container.current.currentScope;
    } on StateError {
      return _isolate;
    }
    if (scope == null) {
      return _isolate;
    }
    final existing = scope.get<ContextRepository>();
    if (existing != null) {
      return existing;
    }
    final created = ContextRepository();
    scope.put<ContextRepository>(created);
    return created;
  }

  static void add(String key, Object? value) => current.data[key] = value;

  static void addMany(Map<String, Object?> values) =>
      current.data.addAll(values);

  /// Adds [key] only when it is not set yet.
  static void addIf(String key, Object? value) =>
      current.data.putIfAbsent(key, () => value);

  /// Appends [values] to the list at [key] (`Context::push`).
  static void push(String key, List<Object?> values) {
    final existing = current.data[key];
    current.data[key] = [if (existing is List<Object?>) ...existing, ...values];
  }

  static T? get<T>(String key, [T? fallback]) =>
      current.data[key] as T? ?? fallback;

  static bool has(String key) => current.data.containsKey(key);

  static void forget(String key) => current.data.remove(key);

  /// Every visible entry.
  static Map<String, Object?> all() => Map.unmodifiable(current.data);

  /// Carried into queued jobs like the rest, but never logged.
  static void addHidden(String key, Object? value) =>
      current.hidden[key] = value;

  static T? getHidden<T>(String key, [T? fallback]) =>
      current.hidden[key] as T? ?? fallback;

  static bool hasHidden(String key) => current.hidden.containsKey(key);

  static void forgetHidden(String key) => current.hidden.remove(key);

  static Map<String, Object?> allHidden() => Map.unmodifiable(current.hidden);

  /// Visible entries without creating a repository (for log records).
  static Map<String, Object?> get forLogging {
    try {
      final scope = Container.current.currentScope;
      return scope == null
          ? _isolate.data
          : scope.get<ContextRepository>()?.data ?? const {};
    } on StateError {
      return _isolate.data;
    }
  }
}
