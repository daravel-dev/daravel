import 'dart:async';

import 'exceptions.dart';

/// Cooperative cancellation of a unit of work, such as one attempt of a
/// queued job.
///
/// Dart cannot stop a running `Future`: work that has been given up (a job
/// past its timeout) keeps running until it returns. The token marks that
/// work as given up, and code that reaches a point of no return checks it:
/// `DB.transaction` rolls back instead of committing when the
/// token of its zone is cancelled, so a handler that outlived its timeout
/// cannot write after the job was released or recorded as failed.
///
/// [run] makes a token [current] for everything its body starts, across
/// `await`s and timers.
final class CancellationToken {
  /// A token that is not cancelled yet.
  CancellationToken();

  static final Object _key = Object();

  /// The token of the current zone, or null outside [run].
  static CancellationToken? get current =>
      Zone.current[_key] as CancellationToken?;

  bool _cancelled = false;
  Object? _reason;

  /// Whether [cancel] was called.
  bool get isCancelled => _cancelled;

  /// Why the work was cancelled.
  Object? get reason => _reason;

  /// Marks the work as given up; later checks throw.
  void cancel([Object? reason]) {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    _reason = reason;
  }

  /// Throws [OperationCancelledException] once [cancel] was called.
  void throwIfCancelled() {
    if (_cancelled) {
      throw OperationCancelledException(_reason);
    }
  }

  /// Runs [body] with this token as [current].
  R run<R>(R Function() body) =>
      runZoned(body, zoneValues: <Object?, Object?>{_key: this});
}

/// Thrown by [CancellationToken.throwIfCancelled]: the work was given up,
/// and what it was about to do (commit a transaction) did not happen.
final class OperationCancelledException extends DaravelException {
  /// The work was cancelled because of [reason].
  OperationCancelledException(this.reason)
    : super(
        'The operation was cancelled${reason == null ? '' : ': $reason'}; '
        'nothing was committed.',
      );

  /// What [CancellationToken.cancel] was given.
  final Object? reason;
}
