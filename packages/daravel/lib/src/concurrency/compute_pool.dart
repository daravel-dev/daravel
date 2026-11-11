import 'dart:async';
import 'dart:collection';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'isolate_payload.dart';

/// Thrown by [ComputePool.run] when the pool cannot take the task: its wait
/// queue is full, or no worker freed up within `queueTimeout`.
final class ComputePoolSaturatedError extends StateError {
  /// The pool refused a task, saying why in [message].
  ComputePoolSaturatedError(super.message);
}

/// Warm worker isolates, spawned on demand up to [maxWorkers].
///
/// Between tasks the caller holds only `SendPort`s and an exit port that does
/// not keep it alive, so an idle pool never holds a CLI or a test process open.
///
/// A task that finds every worker busy waits in a queue of at most
/// [maxQueue] tasks (unbounded when it returns null); past that it fails at
/// once with [ComputePoolSaturatedError].
final class ComputePool {
  /// A pool of at most [maxWorkers] isolates, with at most [maxQueue] tasks
  /// waiting for one.
  ComputePool(this.maxWorkers, {int? Function()? maxQueue, this.beforeSpawn})
    : maxQueue = maxQueue ?? _unbounded;

  static int? _unbounded() => null;

  /// Read at each spawn, so it can change between runs.
  final int Function() maxWorkers;

  /// Read at each queued task: the most tasks waiting for a worker, or null
  /// for no limit.
  final int? Function() maxQueue;

  /// Runs before each spawn; when it throws, the spawn fails with its
  /// error (tests use it to stand in for an isolate that cannot start).
  final FutureOr<void> Function()? beforeSpawn;

  final Set<_Worker> _workers = <_Worker>{};
  final List<_Worker> _idle = <_Worker>[];
  final ListQueue<_Waiter> _waiters = ListQueue<_Waiter>();
  int _spawning = 0;

  /// Bumped by [shutdown], so a spawn in flight knows it is too late.
  int _epoch = 0;

  /// Workers alive right now.
  int get size => _workers.length;

  /// Tasks waiting for a worker right now.
  int get waiting => _waiters.length;

  /// Runs [task] on a worker. An error comes back with its stack trace and
  /// leaves the worker usable.
  ///
  /// [timeout] runs from this call, so it covers the wait for a worker as
  /// well as the task: past it the call fails with a [TimeoutException],
  /// and a task already running costs the worker its isolate.
  /// [queueTimeout] bounds the wait alone and fails with
  /// [ComputePoolSaturatedError], like a full queue.
  Future<T> run<T>(
    FutureOr<T> Function() task, {
    Duration? timeout,
    Duration? queueTimeout,
  }) async {
    final started = Stopwatch()..start();
    final worker = await _acquire(timeout, queueTimeout);
    try {
      return await worker.run(task, _remaining(timeout, started)) as T;
    } finally {
      _release(worker);
    }
  }

  /// [run] for a binary result (ADR-031): the worker sends it as an
  /// [IsolatePayload.bytes], so from [IsolatePayload.transferThreshold] on
  /// it moves here without a second copy. It is materialized in the reply
  /// handler, once. Errors, [timeout] and [queueTimeout] behave as in [run].
  Future<Uint8List> runBytes(
    FutureOr<Uint8List> Function() task, {
    Duration? timeout,
    Duration? queueTimeout,
  }) async {
    final started = Stopwatch()..start();
    final worker = await _acquire(timeout, queueTimeout);
    try {
      return await worker.run(
        _sendsBytes(task),
        _remaining(timeout, started),
        _fromWire,
      ) as Uint8List;
    } finally {
      _release(worker);
    }
  }

  /// What is left of [timeout]; at least a microsecond, so a task that got
  /// its worker just in time still fails by the timer, not before sending.
  static Duration? _remaining(Duration? timeout, Stopwatch started) {
    if (timeout == null) {
      return null;
    }
    final left = timeout - started.elapsed;
    return left > Duration.zero ? left : const Duration(microseconds: 1);
  }

  Future<_Worker> _acquire(Duration? timeout, Duration? queueTimeout) async {
    if (_idle.isNotEmpty) {
      return _idle.removeLast();
    }
    if (_workers.length + _spawning >= math.max(1, maxWorkers())) {
      final limit = maxQueue();
      if (limit != null && _waiters.length >= limit) {
        throw ComputePoolSaturatedError(
          'The compute pool queue is full ($limit tasks waiting).',
        );
      }
      final waiter = _Waiter();
      _waiters.add(waiter);
      // The earlier of the two limits ends the wait.
      final queueFirst =
          queueTimeout != null && (timeout == null || queueTimeout < timeout);
      final wait = queueFirst ? queueTimeout : timeout;
      if (wait != null) {
        waiter.timer = Timer(wait, () {
          if (waiter.completer.isCompleted) {
            return;
          }
          _waiters.remove(waiter);
          waiter.completeError(
            queueFirst
                ? ComputePoolSaturatedError(
                    'No compute worker was free within $wait.',
                  )
                : TimeoutException('No compute worker was free in time.', wait),
          );
        });
      }
      return waiter.completer.future;
    }
    _spawning++;
    try {
      return await _spawn();
    } finally {
      _spawning--;
      // This spawn may have failed while others queued behind it.
      _serveWaiters();
    }
  }

  Future<_Worker> _spawn() async {
    final epoch = _epoch;
    await beforeSpawn?.call();
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
      _serveWaiters();
      return;
    }
    if (_waiters.isNotEmpty) {
      _waiters.removeFirst().complete(worker);
    } else {
      _idle.add(worker);
    }
  }

  /// Spawns a worker for each waiting task there is room for. A spawn that
  /// fails fails its waiter and tries the next, so a failing spawn never
  /// leaves tasks waiting for a worker that will not come.
  void _serveWaiters() {
    while (_waiters.isNotEmpty &&
        _workers.length + _spawning < math.max(1, maxWorkers())) {
      unawaited(_spawnFor(_waiters.removeFirst()));
    }
  }

  Future<void> _spawnFor(_Waiter waiter) async {
    _spawning++;
    _Worker? worker;
    try {
      worker = await _spawn();
    } catch (error, stackTrace) {
      waiter.completeError(error, stackTrace);
    } finally {
      _spawning--;
    }
    if (worker == null) {
      _serveWaiters();
    } else if (waiter.completer.isCompleted) {
      // It timed out meanwhile: the worker serves the next one.
      _release(worker);
    } else {
      waiter.complete(worker);
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

/// A task waiting for a worker.
final class _Waiter {
  final Completer<_Worker> completer = Completer<_Worker>();
  Timer? timer;

  void complete(_Worker worker) {
    timer?.cancel();
    completer.complete(worker);
  }

  void completeError(Object error, [StackTrace? stackTrace]) {
    timer?.cancel();
    if (!completer.isCompleted) {
      completer.completeError(error, stackTrace);
    }
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

  /// [decode] turns a successful reply into the result, in the handler.
  Future<Object?> run(
    Object? task,
    Duration? timeout, [
    Object? Function(Object? value)? decode,
  ]) {
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
            if (decode == null) {
              done.complete(value);
            } else {
              try {
                done.complete(decode(value));
              } catch (error, stackTrace) {
                done.completeError(error, stackTrace);
              }
            }
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
    // Waited for now: the exit port, idle so far so an idle pool never held
    // the isolate open, must keep it alive until the exit arrives. Otherwise
    // an isolate with nothing else to do ends inside this wait, and the
    // caller's shutdown never returns (a command's last output was lost).
    _exit.keepIsolateAlive = true;
    _kill();
    return stopped.future;
  }
}

/// The task a worker runs for [ComputePool.runBytes]. Built here, not in the
/// async method, so the closure captures [task] alone.
FutureOr<Object> Function() _sendsBytes(FutureOr<Uint8List> Function() task) =>
    () async => IsolatePayload.bytes(await task()).toWire();

Object? _fromWire(Object? wire) => IsolatePayload.fromWire(wire!);

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
