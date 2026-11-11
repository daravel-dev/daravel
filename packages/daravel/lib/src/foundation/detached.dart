import 'dart:async';
import 'dart:io';

import 'container.dart';

/// Told of an error a detached task left uncaught: the task's name, the
/// error and its stack trace.
typedef DetachedErrorHandler = void Function(
  String name,
  Object error,
  StackTrace stackTrace,
);

/// The tasks [runDetached] and [runDetachedAsync] started for one
/// application (bound in its container at boot), stopped when it shuts
/// down.
final class DetachedTasks {
  /// Tasks whose uncaught errors go to [onError] (to [onStopError] once
  /// they are being stopped).
  DetachedTasks({this.onError, this.onStopError});

  /// Where uncaught errors of the tasks go: the application's logger, which
  /// in a detached zone has no request context. Standard error when null.
  DetachedErrorHandler? onError;

  /// Where errors go once [cancelAll] began: a loop interrupted by the
  /// shutdown (its connection closing under it) is expected, not a failure
  /// (the application logs it at debug). [onError] when null.
  DetachedErrorHandler? onStopError;

  final Set<Detached<Object?>> _running = <Detached<Object?>>{};
  bool _stopping = false;

  /// The names of the tasks running now (diagnostics, tests).
  List<String> get names => [for (final task in _running) task.name];

  /// Whether [cancelAll] began.
  bool get stopping => _stopping;

  /// Stops every task (its stop function, which may let an iteration in
  /// progress end), waiting at most [timeout] for all of them.
  Future<void> cancelAll({
    Duration timeout = const Duration(seconds: 2),
  }) async {
    _stopping = true;
    final tasks = [..._running];
    await Future.wait([for (final task in tasks) task.cancel()])
        .timeout(timeout, onTimeout: () => const <void>[]);
  }

  void _report(String name, Object error, StackTrace stackTrace) {
    final handler = _stopping ? onStopError ?? onError : onError;
    if (handler != null) {
      try {
        handler(name, error, stackTrace);
        return;
      } on Object {
        // The handler failed too: fall back to standard error.
      }
    }
    stderr.writeln('Detached task $name failed: $error\n$stackTrace');
  }
}

/// A task started with [runDetached]: what its body returned, and how to
/// stop it.
final class Detached<T> {
  Detached._(this.name, this._tasks, this._stop);

  /// The name it was started with (in logs).
  final String name;

  final DetachedTasks? _tasks;
  final FutureOr<void> Function(T value)? _stop;

  /// What the body returned (a `Timer`, a `StreamSubscription`, ...).
  T get value => _value as T;
  Object? _value;

  /// Whether [cancel] was called.
  bool get cancelled => _cancelled;
  bool _cancelled = false;

  /// Stops it once: its stop function, or the default one (a `Timer` is
  /// cancelled, a `StreamSubscription` too), and forgets it. A stop that
  /// fails is reported as the task's error.
  Future<void> cancel() async {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    _tasks?._running.remove(this);
    try {
      await (_stop ?? _defaultStop<T>)(value);
    } on Object catch (error, stackTrace) {
      (_tasks ?? DetachedTasks())._report(name, error, stackTrace);
    }
  }
}

FutureOr<void> _defaultStop<T>(T value) {
  if (value is Timer) {
    value.cancel();
  } else if (value is StreamSubscription<Object?>) {
    return value.cancel();
  }
}

/// Runs [body] outside the request, job or command that calls it, for work
/// that outlives it: a periodic timer, a stream listened to for the life of
/// the process, a loop.
///
/// A `Timer`, `listen` or `async` body runs in the zone it is created in,
/// and work started lazily by a request lives on in that request's zone:
/// `Container.current` there is the request's scope (its `Request`, its
/// `LogContext`, so its logs carry the first request's `request_id`), its
/// queries count towards that request, a job's cancellation token cancels
/// its transactions, and its uncaught errors reach a handler that finished
/// long ago (Review #149).
///
/// [body] runs in a zone forked from [Zone.root] whose only value is the
/// caller's application container: facades resolve the application, with
/// no scope (open one with `runScoped('command')` per iteration when one is
/// needed), no cancellation token, no transaction and no query capture. An
/// error it leaves uncaught is told to the application's
/// [DetachedTasks.onError] (its logger) with [name], never to the caller.
///
/// The task is registered with the application and stopped when it shuts
/// down: [stop], or by default a `Timer` cancelled and a
/// `StreamSubscription` cancelled. Detached work measures time with the
/// wall clock (`DateTime.now`, `Timer`), not `Clock`: a frozen test clock
/// must not stop it.
///
/// For a body that returns a future the caller awaits, use
/// [runDetachedAsync]: a future made in another error zone does not hand
/// its error to a caller in this one.
Detached<T> runDetached<T>(
  T Function() body, {
  required String name,
  FutureOr<void> Function(T value)? stop,
}) {
  final container = Container.currentOrNull;
  final tasks = container?.tryMake<DetachedTasks>();
  final task = Detached<T>._(name, tasks, stop);
  task._value = _detachedZone(container, name, tasks).run(body);
  tasks?._running.add(task);
  return task;
}

/// [runDetached] for a body that returns a future: [Detached.value] is a
/// future of the caller's zone, completed with the body's result or its
/// error (so the caller gets it), while what the body starts runs on
/// detached. Without [stop] the task is forgotten once the future
/// completes; with one, it is kept until the application stops it.
///
/// The future is made by a `Completer` of the caller's zone, so it serves
/// one caller (or callers of that zone). When callers of several zones
/// share the result (a connection every request waits for, a start every
/// connection waits for), wrap it in a `SharedResult`:
/// `SharedResult(() => runDetachedAsync(open, name: ...).value)`, so each
/// gets the error in its own zone (Review #147).
///
/// The caller must handle [Detached.value]: await it, or attach a handler.
/// Its error is delivered there and nowhere else (not to
/// [DetachedTasks.onError]). A [Detached.value] that fails with no handler
/// is an uncaught error of the caller's zone, which ends up in the request's,
/// job's or command's error handler, or ends the isolate outside one, as
/// any unhandled future does. Only what [body] starts and leaves uncaught,
/// beyond its returned future, goes to [DetachedTasks.onError].
Detached<Future<T>> runDetachedAsync<T>(
  Future<T> Function() body, {
  required String name,
  FutureOr<void> Function()? stop,
}) {
  final done = Completer<T>(); // the caller's zone
  late final Detached<Future<T>> task;
  // Forgotten once the body completes, from the body's future: a listener
  // on [done]'s future would count as the caller's handler and swallow an
  // error nobody awaits.
  void forget() {
    if (stop == null) {
      task._tasks?._running.remove(task);
    }
  }

  task = runDetached<Future<T>>(
    () {
      body().then(
        (value) {
          forget();
          done.complete(value);
        },
        onError: (Object error, StackTrace stackTrace) {
          forget();
          done.completeError(error, stackTrace);
        },
      );
      return done.future;
    },
    name: name,
    stop: stop == null ? (_) {} : (_) => stop(),
  );
  return task;
}

Zone _detachedZone(Container? container, String name, DetachedTasks? tasks) {
  final specification = ZoneSpecification(
    handleUncaughtError: (self, parent, zone, error, stackTrace) =>
        (tasks ?? DetachedTasks())._report(name, error, stackTrace),
  );
  return container?.forkDetached(specification) ??
      Zone.root.fork(specification: specification);
}
