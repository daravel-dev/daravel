import 'dart:async';

/// The result of one computation awaited by several callers that may run
/// in different zones: requests, jobs, connections.
///
/// Each request runs in an error zone of its own (`Container.runScoped`),
/// and a future that fails in one error zone never hands its error to a
/// listener in another: that listener waits for ever (until a timeout
/// further out). So a computation started by one request and shared with
/// the others, as single-flight caches, leases and connection pools do,
/// must not be shared as a future that can fail. A [SharedResult] holds
/// one that never fails: it completes with the value or with the error,
/// and [value] raises that error again, with its own stack trace, in the
/// zone of each caller, the one that started it included. Programming
/// errors ([Error]) are raised to every caller the same way; nothing is
/// swallowed, and no error is left uncaught in any zone.
///
/// ```dart
/// final pending = _inFlight[key] ??= SharedResult(() => load(key));
/// try {
///   return await pending.value;
/// } finally {
///   if (identical(_inFlight[key], pending)) _inFlight.remove(key);
/// }
/// ```
final class SharedResult<T> {
  /// Starts [compute] now, in the current zone.
  SharedResult(Future<T> Function() compute) : _settled = _settle(compute);

  final Future<_Outcome<T>> _settled;

  static Future<_Outcome<T>> _settle<T>(Future<T> Function() compute) async {
    try {
      return _Outcome<T>.value(await compute());
    } on Object catch (error, stackTrace) {
      return _Outcome<T>.error(error, stackTrace);
    }
  }

  /// The value, or the computation's error raised with its stack trace,
  /// in the caller's zone. Safe to await from any zone, any number of
  /// times.
  Future<T> get value async {
    final outcome = await _settled;
    final error = outcome.error;
    if (error != null) {
      Error.throwWithStackTrace(error, outcome.stackTrace!);
    }
    return outcome.result as T;
  }

  /// Completes, with nothing, when the computation has ended, whether it
  /// succeeded or failed; never fails.
  Future<void> get done => _settled;
}

final class _Outcome<T> {
  _Outcome.value(this.result) : error = null, stackTrace = null;
  _Outcome.error(Object this.error, StackTrace this.stackTrace) : result = null;

  final T? result;
  final Object? error;
  final StackTrace? stackTrace;
}
