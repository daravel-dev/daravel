import 'dart:async';

/// Completes when the application starts shutting down (SIGTERM or
/// `ServerEngine.stop`): long-lived responses (server-sent events) end
/// cleanly so clients reconnect elsewhere, instead of holding the shutdown
/// until its timeout.
final class DrainSignal {
  final Completer<void> _completer = Completer<void>();
  final Set<_Listener> _listeners = <_Listener>{};

  /// Completes once draining starts. A callback added with `then` stays
  /// until then, with everything it holds: a response that ends earlier
  /// uses [onDrain] and removes its listener.
  Future<void> get future => _completer.future;

  /// Whether draining has started.
  bool get isDraining => _completer.isCompleted;

  /// Listeners added with [onDrain] and not removed yet.
  int get listenerCount => _listeners.length;

  /// Calls [listener] once draining starts (soon, when it has started) and
  /// returns a function that removes it, so a stream that ends first lets
  /// go of it instead of holding it until shutdown.
  void Function() onDrain(void Function() listener) {
    if (isDraining) {
      scheduleMicrotask(listener);
      return () {};
    }
    final entry = _Listener(listener);
    _listeners.add(entry);
    return () => _listeners.remove(entry);
  }

  /// Starts draining; later calls do nothing.
  void signal() {
    if (_completer.isCompleted) {
      return;
    }
    _completer.complete();
    final listeners = [..._listeners];
    _listeners.clear();
    for (final entry in listeners) {
      try {
        entry.call();
      } catch (error, stackTrace) {
        // One failing listener must not keep the others from ending.
        Zone.current.handleUncaughtError(error, stackTrace);
      }
    }
  }
}

/// One [DrainSignal.onDrain] registration (identity, so the same function
/// added twice is two listeners).
final class _Listener {
  _Listener(this.call);

  final void Function() call;
}
