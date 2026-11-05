import 'dart:async';
import 'dart:isolate';

import '../foundation/exceptions.dart';

/// Where a piece of state lives (ADR-003).
enum StateScope {
  /// Fast, but every isolate has its own copy.
  isolate,

  /// Consistent within one process: served by the coordinator isolate.
  process,

  /// Shared across processes/servers (Redis, database).
  cluster,
}

/// A request to a coordinator service.
final class CoordinatorRequest {
  /// A call of [op] on [service], answered on [replyTo].
  const CoordinatorRequest({
    required this.id,
    required this.service,
    required this.op,
    required this.args,
    required this.replyTo,
  });

  /// The call's id, matching its reply.
  final int id;

  /// The service called.
  final String service;

  /// The operation; empty for a typed message, which names its own.
  final String op;

  /// Its arguments: a `Map<String, Object?>` for
  /// [CoordinatorService.handle], or the typed message of a
  /// [TypedCoordinatorService] ([TypedCoordinatorChannel.callTyped]).
  final Object args;

  /// Where the reply goes.
  final SendPort replyTo;
}

/// Reply to a [CoordinatorRequest].
final class CoordinatorReply {
  /// The reply to call [id]: a [result] or an [error].
  const CoordinatorReply(this.id, {this.result, this.error});

  /// The call's id.
  final int id;

  /// The result.
  final Object? result;

  /// The error message, when the call failed.
  final String? error;
}

/// Raised when the coordinator rejects or cannot process a request.
final class CoordinatorException extends DaravelException {
  /// A coordinator call failed.
  const CoordinatorException(super.message);
}

/// Raised when the coordinator does not answer within the timeout.
final class CoordinatorTimeoutException extends CoordinatorException {
  /// [service] did not answer within [timeout].
  CoordinatorTimeoutException(String service, Duration timeout)
    : super(
        'Coordinator service [$service] did not answer within '
        '${timeout.inMilliseconds}ms.',
      );
}

/// Marks a typed coordinator message (ADR-032): an object sent to a
/// [TypedCoordinatorService] through [TypedCoordinatorChannel.callTyped],
/// or returned by one.
///
/// The contract, which the VM checks once the pragma is present:
/// - the class is `final` and annotated `@pragma('vm:deeply-immutable')`;
/// - its fields are final and only `int`, `double`, `bool`, `String` (or
///   nullable ones) or other `@pragma('vm:deeply-immutable')` classes. No
///   `List`, `Map` or `Set`: the compiler rejects them, so a collection
///   travels as a JSON `String` or a nested immutable class.
///
/// Such an object crosses to another isolate of the process by reference
/// instead of being copied, so a batch of them (a `List` of 10 000
/// messages) costs little more than the copy of the list itself, many
/// times less than plain objects (`bench/bin/isolate_payload.dart`). For
/// one small message the port's own overhead dominates and a map costs
/// about the same.
///
/// Implement it (`final class M implements CoordinatorMessage`) rather
/// than extend it: a deeply-immutable class may only extend another
/// deeply-immutable class, which must itself be `final` or `sealed` and so
/// cannot be extended from another library. Custom coordinator services
/// may send their own such classes. `test/server/deeply_immutable_test.dart`
/// checks that every implementation in the framework carries the pragma.
/// The pragma is a VM contract, not a language feature: keep it on
/// coordinator messages, not on an application's models or DTOs.
abstract interface class CoordinatorMessage {}

/// A service hosted by the [Coordinator] (rate limiter, locks, cache...).
abstract interface class CoordinatorService {
  /// The service's name.
  String get name;

  /// Handles [op] and returns a sendable result.
  FutureOr<Object?> handle(String op, Map<String, Object?> args);

  /// Debug snapshot (`dartisan coordinator:stats`).
  Map<String, Object?> stats();
}

/// A [CoordinatorService] that also answers typed messages of type [M]
/// (ADR-031): one small immutable object per call instead of a map whose
/// entries the VM copies, used on the hottest paths (rate limits, locks).
/// [CoordinatorService.handle] keeps answering the same operations as maps,
/// for channels that are not a [TypedCoordinatorChannel].
///
/// A message class marked `@pragma('vm:deeply-immutable')` (final fields of
/// strings, numbers, booleans and null only) crosses to the coordinator
/// isolate by reference, without a copy.
abstract interface class TypedCoordinatorService<M extends Object>
    implements CoordinatorService {
  /// Handles [message] and returns a sendable result.
  FutureOr<Object?> handleTyped(M message);
}

/// A [CoordinatorService] holding state on behalf of worker isolates
/// (presence members, broadcast ports): told when a worker is gone, so
/// what it registered does not outlive it. Workers name themselves with
/// `Isolate.current.debugName` (`daravel-worker-N` under a supervisor).
abstract interface class WorkerAwareService {
  /// Forgets everything registered by [worker], which has exited without
  /// unregistering it (a crash, a kill).
  void forgetWorker(String worker);
}

/// Hosts `process`-scope services. Lives in the supervisor (main) isolate
/// when serving with several workers; in-process otherwise.
final class Coordinator {
  /// A coordinator queueing at most [maxQueue] calls.
  Coordinator({this.maxQueue = 10000});

  /// Pending requests above this count are rejected (backpressure).
  final int maxQueue;

  final Map<String, CoordinatorService> _services =
      <String, CoordinatorService>{};
  ReceivePort? _port;
  int _inFlight = 0;
  int _peakInFlight = 0;
  int _handled = 0;
  int _rejected = 0;

  /// Since construction, for the message rate in [stats] (wall clock: not
  /// domain time, so not `Clock`).
  final Stopwatch _uptime = Stopwatch()..start();

  /// Registers [service].
  void register(CoordinatorService service) =>
      _services[service.name] = service;

  /// The service named [name], or null.
  CoordinatorService? service(String name) => _services[name];

  /// The names of the registered services.
  Iterable<String> get serviceNames => _services.keys;

  /// Tells every [WorkerAwareService] that [worker] is gone (the
  /// supervisor calls it on a worker's exit).
  void forgetWorker(String worker) {
    for (final service in _services.values) {
      if (service is WorkerAwareService) {
        (service as WorkerAwareService).forgetWorker(worker);
      }
    }
  }

  /// Dispatches directly (used by [LocalCoordinatorChannel]).
  Future<Object?> handle(
    String service,
    String op,
    Map<String, Object?> args,
  ) => _handleHere(service, op, args);

  /// Dispatches a typed [message] directly to [service], a
  /// [TypedCoordinatorService] (used by [LocalCoordinatorChannel]).
  Future<Object?> handleTyped(String service, Object message) =>
      _handleHere(service, '', message);

  Future<Object?> _handleHere(String service, String op, Object args) {
    try {
      final result = _invoke(service, op, args);
      return result is Future<Object?> ? result : Future<Object?>.value(result);
    } on Object catch (error, stackTrace) {
      return Future<Object?>.error(error, stackTrace);
    }
  }

  /// A map goes to [CoordinatorService.handle], anything else to
  /// [TypedCoordinatorService.handleTyped]; a message of another type than
  /// the service's fails that call's parameter check (a `TypeError`).
  FutureOr<Object?> _invoke(String service, String op, Object args) {
    final target = _services[service];
    if (target == null) {
      throw CoordinatorException('Unknown coordinator service [$service].');
    }
    _handled++;
    if (args is Map<String, Object?>) {
      return target.handle(op, args);
    }
    if (target is TypedCoordinatorService<Object>) {
      return target.handleTyped(args);
    }
    throw CoordinatorException(
      'Coordinator service [$service] takes no typed messages '
      '(got ${args.runtimeType}).',
    );
  }

  /// Starts listening for remote requests and returns the port workers
  /// send to.
  SendPort listen() {
    final existing = _port;
    if (existing != null) {
      return existing.sendPort;
    }
    final port = ReceivePort('daravel-coordinator');
    _port = port;
    port.listen((Object? message) {
      if (message is! CoordinatorRequest) {
        return;
      }
      if (_inFlight >= maxQueue) {
        _rejected++;
        _reply(
          message,
          CoordinatorReply(message.id, error: 'Coordinator queue is full.'),
        );
        return;
      }
      // Synchronous services (rate limits, memory cache, locks) answer
      // inline: no Future or microtask per message.
      final FutureOr<Object?> result;
      try {
        result = _invoke(message.service, message.op, message.args);
      } on Object catch (error) {
        _reply(message, CoordinatorReply(message.id, error: '$error'));
        return;
      }
      if (result is! Future<Object?>) {
        _reply(message, CoordinatorReply(message.id, result: result));
        return;
      }
      if (++_inFlight > _peakInFlight) {
        _peakInFlight = _inFlight;
      }
      unawaited(_dispatch(message, result));
    });
    return port.sendPort;
  }

  /// Sends [reply] to the worker. A result that cannot cross an isolate
  /// (a closure, a socket) makes `send` throw; this listener runs on the
  /// supervisor's main isolate, where an uncaught error ends the whole
  /// server, so the worker gets the error as an answer instead.
  static void _reply(CoordinatorRequest request, CoordinatorReply reply) {
    try {
      request.replyTo.send(reply);
    } on Object catch (error) {
      request.replyTo.send(
        CoordinatorReply(
          request.id,
          error:
              'Coordinator service [${request.service}] returned a value '
              'that cannot be sent to a worker: $error',
        ),
      );
    }
  }

  Future<void> _dispatch(
    CoordinatorRequest request,
    Future<Object?> pending,
  ) async {
    try {
      final result = await pending;
      _reply(request, CoordinatorReply(request.id, result: result));
    } catch (error) {
      _reply(request, CoordinatorReply(request.id, error: '$error'));
    } finally {
      _inFlight--;
    }
  }

  /// Counters, the message rate and each service's snapshot. `messages`
  /// (handled plus rejected) only grows; with `uptime_s`, or by reading the
  /// stats twice, it shows a flood of messages from the workers, which the
  /// coordinator answers on the supervisor's own event loop.
  Map<String, Object?> stats() {
    final messages = _handled + _rejected;
    final seconds = _uptime.elapsedMicroseconds / 1e6;
    return <String, Object?>{
      'handled': _handled,
      'rejected': _rejected,
      'messages': messages,
      'uptime_s': double.parse(seconds.toStringAsFixed(1)),
      'messages_per_second': seconds == 0
          ? 0.0
          : double.parse((messages / seconds).toStringAsFixed(1)),
      'in_flight': _inFlight,
      // How close the asynchronous calls came to [maxQueue], where calls
      // start to be refused.
      'in_flight_peak': _peakInFlight,
      'max_queue': maxQueue,
      'services': <String, Object?>{
        for (final entry in _services.entries) entry.key: entry.value.stats(),
      },
    };
  }

  /// Whether [listen] opened a port that [close] has not closed yet. An
  /// open port keeps its isolate alive, so a server that stopped must
  /// have closed it.
  bool get isListening => _port != null;

  /// Stops the coordinator.
  void close() {
    _port?.close();
    _port = null;
  }
}

/// How application code reaches the coordinator.
abstract interface class CoordinatorChannel {
  /// `process` when backed by a coordinator (local or remote).
  StateScope get scope;

  /// Whether calls cross an isolate boundary.
  bool get isRemote;

  /// Calls an operation of a service.
  Future<Object?> call(
    String service,
    String op,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 1),
  });
}

/// A [CoordinatorChannel] that also sends typed messages to a
/// [TypedCoordinatorService]. [LocalCoordinatorChannel] and
/// [RemoteCoordinatorChannel] are both. A channel that is only a
/// [CoordinatorChannel] (an application's own, a test double) keeps
/// working: the framework's stores send it the same operation as a map
/// through [call].
abstract interface class TypedCoordinatorChannel implements CoordinatorChannel {
  /// Sends [message] (not a `Map`: maps go through [call]) to the
  /// [TypedCoordinatorService] named [service].
  Future<Object?> callTyped(
    String service,
    Object message, {
    Duration timeout = const Duration(seconds: 1),
  });
}

/// Direct in-process calls (single isolate / tests): no message hop.
final class LocalCoordinatorChannel implements TypedCoordinatorChannel {
  /// A channel to [coordinator] in this isolate.
  const LocalCoordinatorChannel(this.coordinator);

  /// The coordinator called.
  final Coordinator coordinator;

  @override
  StateScope get scope => StateScope.process;

  @override
  bool get isRemote => false;

  @override
  Future<Object?> call(
    String service,
    String op,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 1),
  }) => coordinator.handle(service, op, args);

  @override
  Future<Object?> callTyped(
    String service,
    Object message, {
    Duration timeout = const Duration(seconds: 1),
  }) => coordinator.handleTyped(service, message);
}

/// Request/response over [SendPort] with correlation ids and timeouts.
final class RemoteCoordinatorChannel implements TypedCoordinatorChannel {
  /// A channel to a coordinator in another isolate.
  RemoteCoordinatorChannel(this._target) {
    _replies = ReceivePort('daravel-coordinator-client');
    _replies.listen(_onReply);
  }

  final SendPort _target;
  late final ReceivePort _replies;

  /// Receives each answered call's service and round trip, the wait in
  /// the coordinator's queue included (`coordinator_call_duration_seconds`
  /// on `/metrics`).
  void Function(String service, Duration roundTrip)? onCallDuration;

  /// Receives the service of each call that timed out.
  void Function(String service)? onCallTimeout;
  final Map<int, _PendingCall> _pending = <int, _PendingCall>{};
  int _nextId = 0;
  bool _closed = false;

  /// Monotonic clock for deadlines; one sweep [Timer] enforces every call's
  /// timeout instead of a timer per call (the happy path allocates none).
  final Stopwatch _clock = Stopwatch()..start();
  Timer? _sweeper;

  /// Interval of the timeout sweep (timeouts fire within this much).
  static const Duration sweepInterval = Duration(milliseconds: 10);

  @override
  StateScope get scope => StateScope.process;

  @override
  bool get isRemote => true;

  /// The calls waiting for a reply.
  int get pending => _pending.length;

  @override
  Future<Object?> call(
    String service,
    String op,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 1),
  }) => _send(service, op, args, timeout);

  @override
  Future<Object?> callTyped(
    String service,
    Object message, {
    Duration timeout = const Duration(seconds: 1),
  }) => _send(service, '', message, timeout);

  Future<Object?> _send(
    String service,
    String op,
    Object args,
    Duration timeout,
  ) {
    if (_closed) {
      // After close() no reply can arrive: fail now rather than after the
      // timeout (and without restarting the sweeper).
      return Future<Object?>.error(
        const CoordinatorException('Coordinator channel closed.'),
      );
    }
    final id = _nextId++;
    final now = _clock.elapsedMicroseconds;
    final call = _PendingCall(
      service,
      timeout,
      now + timeout.inMicroseconds,
      now,
    );
    _pending[id] = call;
    _sweeper ??= Timer.periodic(sweepInterval, (_) => _sweep());
    _target.send(
      CoordinatorRequest(
        id: id,
        service: service,
        op: op,
        args: args,
        replyTo: _replies.sendPort,
      ),
    );
    return call.completer.future;
  }

  void _sweep() {
    final now = _clock.elapsedMicroseconds;
    _pending.removeWhere((_, call) {
      if (now < call.deadline) {
        return false;
      }
      call.completer.completeError(
        CoordinatorTimeoutException(call.service, call.timeout),
      );
      onCallTimeout?.call(call.service);
      return true;
    });
    if (_pending.isEmpty) {
      _sweeper?.cancel();
      _sweeper = null;
    }
  }

  void _onReply(Object? message) {
    if (message is! CoordinatorReply) {
      return;
    }
    final call = _pending.remove(message.id);
    if (call == null) {
      return;
    }
    onCallDuration?.call(
      call.service,
      Duration(microseconds: _clock.elapsedMicroseconds - call.started),
    );
    final error = message.error;
    if (error != null) {
      call.completer.completeError(CoordinatorException(error));
    } else {
      call.completer.complete(message.result);
    }
  }

  /// Closes the channel.
  void close() {
    _closed = true;
    _sweeper?.cancel();
    _sweeper = null;
    _replies.close();
    for (final call in _pending.values) {
      call.completer.completeError(
        const CoordinatorException('Coordinator channel closed.'),
      );
    }
    _pending.clear();
  }
}

/// An in-flight [RemoteCoordinatorChannel.call].
final class _PendingCall {
  _PendingCall(this.service, this.timeout, this.deadline, this.started);

  final String service;
  final Duration timeout;

  /// Monotonic microseconds after which the call times out.
  final int deadline;

  /// Monotonic microseconds when the call was sent.
  final int started;
  final Completer<Object?> completer = Completer<Object?>();
}
