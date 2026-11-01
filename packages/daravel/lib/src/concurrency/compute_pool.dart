import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;

/// Warm worker isolates, spawned on demand up to [maxWorkers].
///
/// Between tasks the caller holds only `SendPort`s and an exit port that does
/// not keep it alive, so an idle pool never holds a CLI or a test process open.
final class ComputePool {
  ComputePool(this.maxWorkers);

  /// Read at each spawn, so it can change between runs.
  final int Function() maxWorkers;

  final Set<_Worker> _workers = <_Worker>{};
  final List<_Worker> _idle = <_Worker>[];
  final List<Completer<_Worker>> _waiters = <Completer<_Worker>>[];
  int _spawning = 0;

  /// Bumped by [shutdown], so a spawn in flight knows it is too late.
  int _epoch = 0;

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
    if (_workers.length + _spawning >= math.max(1, maxWorkers())) {
      final waiter = Completer<_Worker>();
      _waiters.add(waiter);
      return waiter.future;
    }
    _spawning++;
    try {
      return await _spawn();
    } finally {
      _spawning--;
    }
  }

  Future<_Worker> _spawn() async {
    final epoch = _epoch;
    final worker = await _Worker.spawn(_forget);
    if (epoch != _epoch) {
      await worker.stop();
      throw StateError('The compute pool was shut down.');
    }
    _workers.add(worker);
    return worker;
  }

  /// A worker went away, perhaps while idle: nothing may be sent to it again.
  void _forget(_Worker worker) {
    _workers.remove(worker);
    _idle.remove(worker);
  }

  void _release(_Worker worker) {
    if (!worker.alive) {
      _forget(worker);
      if (_waiters.isNotEmpty) {
        unawaited(_replace(_waiters.removeAt(0)));
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
      waiter.complete(await _spawn());
    } catch (error, stackTrace) {
      waiter.completeError(error, stackTrace);
    }
  }

  /// Stops every worker. Tasks still running fail; the next run spawns anew.
  Future<void> shutdown() async {
    _epoch++;
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
  _Worker(this._isolate, this._port, this._exit, this._onDeath);

  static Future<_Worker> spawn(void Function(_Worker) onDeath) async {
    final ready = Completer<SendPort>();
    final handshake = RawReceivePort((Object? message) {
      ready.complete(message! as SendPort);
    });
    // Given to `spawn`, not added later: `addOnExitListener` sends nothing for
    // an isolate that is already gone. It does not keep this isolate alive.
    final exit = RawReceivePort()..keepIsolateAlive = false;
    _Worker? worker;
    exit.handler = (Object? _) {
      if (!ready.isCompleted) {
        ready.completeError(StateError('The worker exited at start.'));
        exit.close();
      }
      worker?._died();
    };
    try {
      final isolate = await Isolate.spawn(
        _workerMain,
        handshake.sendPort,
        errorsAreFatal: false,
        onExit: exit.sendPort,
        debugName: 'daravel-compute',
      );
      return worker = _Worker(isolate, await ready.future, exit, onDeath);
    } finally {
      handshake.close();
    }
  }

  final Isolate _isolate;
  final SendPort _port;
  final RawReceivePort _exit;
  final void Function(_Worker) _onDeath;

  bool alive = true;
  bool _gone = false;
  void Function()? _abort;
  Completer<void>? _stopped;

  void _died() {
    if (_gone) {
      return;
    }
    _gone = true;
    alive = false;
    _exit.close();
    _onDeath(this);
    _abort?.call();
    _stopped?.complete();
  }

  Future<Object?> run(Object? task, Duration? timeout) {
    final done = Completer<Object?>();
    final reply = RawReceivePort();
    Timer? timer;

    void finish(void Function() complete) {
      if (done.isCompleted) {
        return;
      }
      timer?.cancel();
      _abort = null;
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
        }
      });
    };
    // Without this the caller would wait for ever on `Isolate.exit`.
    _abort = () {
      finish(() {
        done.completeError(
          RemoteError('The worker exited before the task finished.', ''),
          StackTrace.current,
        );
      });
    };
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
    if (_gone) {
      return Future<void>.value();
    }
    final stopped = _stopped ??= Completer<void>();
    _kill();
    return stopped.future;
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
