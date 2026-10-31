import 'dart:async';
import 'dart:isolate';

const String _exited = 'daravel.compute.exited';

/// Warm worker isolates, spawned on demand up to [maxWorkers].
///
/// The caller holds only `SendPort`s between tasks. A port is open just while
/// a task runs, so an idle pool never keeps a CLI or a test process alive.
final class ComputePool {
  ComputePool(this.maxWorkers);

  /// Read at each spawn, so it can change between runs.
  final int Function() maxWorkers;

  final Set<_Worker> _workers = <_Worker>{};
  final List<_Worker> _idle = <_Worker>[];
  final List<Completer<_Worker>> _waiters = <Completer<_Worker>>[];
  int _spawning = 0;

  /// Workers alive right now.
  int get size => _workers.length;

  /// Runs [task] on a worker. An error comes back with its stack trace and
  /// leaves the worker usable; a [timeout] costs the worker its isolate.
  Future<T> run<T>(FutureOr<T> Function() task, {Duration? timeout}) async {
    final worker = await _acquire();
    try {
      return await worker.run(task, timeout) as T;
    } finally {
      _release(worker);
    }
  }

  Future<_Worker> _acquire() async {
    if (_idle.isNotEmpty) {
      return _idle.removeLast();
    }
    if (_workers.length + _spawning >= maxWorkers()) {
      final waiter = Completer<_Worker>();
      _waiters.add(waiter);
      return waiter.future;
    }
    _spawning++;
    try {
      final worker = await _Worker.spawn();
      _workers.add(worker);
      return worker;
    } finally {
      _spawning--;
    }
  }

  void _release(_Worker worker) {
    if (!worker.alive) {
      _workers.remove(worker);
      if (_waiters.isNotEmpty) {
        final waiter = _waiters.removeAt(0);
        unawaited(_replace(waiter));
      }
      return;
    }
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete(worker);
    } else {
      _idle.add(worker);
    }
  }

  Future<void> _replace(Completer<_Worker> waiter) async {
    try {
      final worker = await _Worker.spawn();
      _workers.add(worker);
      waiter.complete(worker);
    } catch (error, stackTrace) {
      waiter.completeError(error, stackTrace);
    }
  }

  /// Stops every worker. Tasks still running fail; the next run spawns anew.
  Future<void> shutdown() async {
    final workers = _workers.toList();
    _workers.clear();
    _idle.clear();
    final waiters = _waiters.toList();
    _waiters.clear();
    for (final waiter in waiters) {
      waiter.completeError(StateError('The compute pool was shut down.'));
    }
    await Future.wait([for (final worker in workers) worker.stop()]);
  }
}

final class _Worker {
  _Worker(this._isolate, this._port);

  static Future<_Worker> spawn() async {
    final ready = Completer<SendPort>();
    final port = RawReceivePort((Object? message) {
      ready.complete(message! as SendPort);
    });
    try {
      final isolate = await Isolate.spawn(
        _workerMain,
        port.sendPort,
        errorsAreFatal: false,
        debugName: 'daravel-compute',
      );
      return _Worker(isolate, await ready.future);
    } finally {
      port.close();
    }
  }

  final Isolate _isolate;
  final SendPort _port;
  bool alive = true;

  Future<Object?> run(Object? task, Duration? timeout) {
    final done = Completer<Object?>();
    final reply = RawReceivePort();
    Timer? timer;

    void finish(void Function() complete) {
      if (done.isCompleted) {
        return;
      }
      timer?.cancel();
      _isolate.removeOnExitListener(reply.sendPort);
      reply.close();
      complete();
    }

    reply.handler = (Object? message) {
      finish(() {
        switch (message) {
          case (true, final Object? value):
            done.complete(value);
          case (false, final Object error, final String stack):
            done.completeError(error, StackTrace.fromString(stack));
          default:
            // The isolate went away with the task: `Isolate.exit`, or a
            // shutdown. Without this the caller would wait for ever.
            alive = false;
            done.completeError(
              RemoteError('The worker exited before the task finished.', ''),
              StackTrace.current,
            );
        }
      });
    };
    _isolate.addOnExitListener(reply.sendPort, response: _exited);
    if (timeout != null) {
      timer = Timer(timeout, () {
        finish(() {
          _kill();
          done.completeError(
            TimeoutException('The task did not finish in time.', timeout),
            StackTrace.current,
          );
        });
      });
    }
    try {
      _port.send((task, reply.sendPort));
    } catch (error, stackTrace) {
      // A closure that captures something unsendable. The worker is fine.
      finish(() => done.completeError(error, stackTrace));
    }
    return done.future;
  }

  void _kill() {
    alive = false;
    _isolate.kill(priority: Isolate.immediate);
  }

  Future<void> stop() {
    final gone = Completer<void>();
    final exit = RawReceivePort((Object? _) {
      if (!gone.isCompleted) {
        gone.complete();
      }
    });
    _isolate.addOnExitListener(exit.sendPort);
    _kill();
    return gone.future.whenComplete(exit.close);
  }
}

void _workerMain(SendPort ready) {
  final inbox = RawReceivePort();
  inbox.handler = (Object? message) {
    final (task, reply) = message! as (Object?, SendPort);
    unawaited(_runTask(task! as FutureOr<Object?> Function(), reply));
  };
  ready.send(inbox.sendPort);
}

Future<void> _runTask(FutureOr<Object?> Function() task, SendPort reply) async {
  try {
    reply.send((true, await task()));
  } catch (error, stackTrace) {
    final stack = '$stackTrace';
    try {
      reply.send((false, error, stack));
    } on ArgumentError {
      // The error itself cannot cross: an exception holding a socket, say.
      reply.send((false, RemoteError('$error', stack), stack));
    }
  }
}
