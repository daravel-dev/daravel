import 'dart:async';

import '../database/orm/model.dart';
import '../foundation/clock.dart';
import '../foundation/container.dart';
import '../logging/logger.dart';

/// Global helpers with Laravel's semantics (BLUEPRINT_V2 §7.12). `abort`,
/// `abortIf` and `abortUnless` live with the HTTP exceptions; `env` with the
/// facades. Laravel's `app()` is `App.make<T>()` (a top-level `app` would
/// be shadowed by the idiomatic `app` variable).

/// The current time from [Clock] (frozen by `freezeTime()` in tests).
DateTime now() => Clock.now();

/// Today at midnight, local time ([Clock] aware).
DateTime today() {
  final current = Clock.now();
  return DateTime(current.year, current.month, current.day);
}

/// Whether [value] is "blank": `null`, a whitespace-only string, or an empty
/// collection or map (`blank()`). Numbers and `false` are not blank.
bool blank(Object? value) => switch (value) {
  null => true,
  final String text => text.trim().isEmpty,
  final Iterable<Object?> items => items.isEmpty,
  final Map<Object?, Object?> map => map.isEmpty,
  _ => false,
};

/// `!blank(value)` (`filled()`).
bool filled(Object? value) => !blank(value);

/// Calls [callback] with [value] and returns [value] (`tap()`).
T tap<T>(T value, void Function(T value) callback) {
  callback(value);
  return value;
}

/// Runs [callback] and returns its result (`value()`), handy for
/// expressions that need statements.
T value<T>(T Function() callback) => callback();

/// Reads [path] (dot notation, `*` not supported) from nested maps, lists
/// and models, or returns [fallback] (`data_get()`).
Object? dataGet(Object? target, String path, [Object? fallback]) {
  if (path.isEmpty) {
    return target ?? fallback;
  }
  Object? current = target;
  for (final segment in path.split('.')) {
    switch (current) {
      case final Map<Object?, Object?> map when map.containsKey(segment):
        current = map[segment];
      case final List<Object?> list:
        final index = int.tryParse(segment);
        if (index == null || index < 0 || index >= list.length) {
          return fallback;
        }
        current = list[index];
      case final Model model:
        current = model.toMap()[segment];
        if (current == null) {
          return fallback;
        }
      default:
        return fallback;
    }
  }
  return current;
}

/// Runs [callback] up to [times] times until it succeeds (`retry()`).
///
/// [delay] waits between attempts (as a function of the attempt number when
/// [backoff] is given); [when] decides whether an error is retried.
Future<T> retry<T>(
  int times,
  FutureOr<T> Function(int attempt) callback, {
  Duration delay = Duration.zero,
  Duration Function(int attempt)? backoff,
  bool Function(Object error)? when,
}) async {
  if (times < 1) {
    throw ArgumentError.value(times, 'times', 'Must be at least 1.');
  }
  for (var attempt = 1; ; attempt++) {
    try {
      return await callback(attempt);
    } on Object catch (error) {
      if (attempt >= times || (when != null && !when(error))) {
        rethrow;
      }
      final wait = backoff?.call(attempt) ?? delay;
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
    }
  }
}

/// Runs [callback], returning [fallback] when it throws (`rescue()`). The
/// error is logged unless [report] is false.
Future<T?> rescue<T>(
  FutureOr<T> Function() callback, {
  T? fallback,
  bool report = true,
}) async {
  try {
    return await callback();
  } on Object catch (error, stackTrace) {
    if (report) {
      try {
        Container.current.make<Logger>().error(
          'rescue() caught an exception',
          error: error,
          stackTrace: stackTrace,
        );
      } on Object {
        // No container or logger: rescuing must not throw.
      }
    }
    return fallback;
  }
}

final Expando<Map<Object, Object?>> _onceCache = Expando('daravel.once');

/// Memoizes [callback] by [key] for the current scope (request, job,
/// command): the first call runs it, later calls in the same scope return
/// the stored result (`once()`). Outside a scope it just runs [callback].
T once<T>(Object key, T Function() callback) {
  final Object? scope;
  try {
    scope = Container.current.currentScope;
  } on StateError {
    return callback();
  }
  if (scope == null) {
    return callback();
  }
  final cache = _onceCache[scope] ??= <Object, Object?>{};
  if (cache.containsKey(key)) {
    return cache[key] as T;
  }
  final result = callback();
  cache[key] = result;
  return result;
}
