import 'dart:async';

/// Completes when the application starts shutting down (SIGTERM or
/// `ServerEngine.stop`): long-lived responses (server-sent events) end
/// cleanly so clients reconnect elsewhere, instead of holding the shutdown
/// until its timeout.
final class DrainSignal {
  final Completer<void> _completer = Completer<void>();

  /// Completes once draining starts.
  Future<void> get future => _completer.future;

  /// Whether draining has started.
  bool get isDraining => _completer.isCompleted;

  /// Starts draining; later calls do nothing.
  void signal() {
    if (!_completer.isCompleted) {
      _completer.complete();
    }
  }
}
