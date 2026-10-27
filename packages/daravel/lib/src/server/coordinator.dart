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
  const CoordinatorRequest({
    required this.id,
    required this.service,
    required this.op,
    required this.args,
    required this.replyTo,
  });

  final int id;
  final String service;
  final String op;
  final Map<String, Object?> args;
  final SendPort replyTo;
}

/// Reply to a [CoordinatorRequest].
final class CoordinatorReply {
  const CoordinatorReply(this.id, {this.result, this.error});

  final int id;
  final Object? result;
  final String? error;
}

/// Raised when the coordinator rejects or cannot process a request.
final class CoordinatorException extends DaravelException {
  const CoordinatorException(super.message);
}

/// Raised when the coordinator does not answer within the timeout.
final class CoordinatorTimeoutException extends CoordinatorException {
  CoordinatorTimeoutException(String service, Duration timeout)
    : super(
        'Coordinator service [$service] did not answer within '
        '${timeout.inMilliseconds}ms.',
      );
}

/// A service hosted by the [Coordinator] (rate limiter, locks, cache...).
abstract interface class CoordinatorService {
  String get name;

  /// Handles [op] and returns a sendable result.
  FutureOr<Object?> handle(String op, Map<String, Object?> args);

  /// Debug snapshot (`dartisan coordinator:stats`).
  Map<String, Object?> stats();
}

/// Hosts `process`-scope services. Lives in the supervisor (main) isolate
/// when serving with several workers; in-process otherwise.
final class Coordinator {
  Coordinator({this.maxQueue = 10000});

  /// Pending requests above this count are rejected (backpressure).
  final int maxQueue;

  final Map<String, CoordinatorService> _services =
      <String, CoordinatorService>{};
  ReceivePort? _port;
  int _inFlight = 0;
  int _handled = 0;
  int _rejected = 0;

  /// Since construction, for the message rate in [stats] (wall clock: not
  /// domain time, so not `Clock`).
  final Stopwatch _uptime = Stopwatch()..start();

  void register(CoordinatorService service) =>
      _services[service.name] = service;

  CoordinatorService? service(String name) => _services[name];

  Iterable<String> get serviceNames => _services.keys;

  /// Dispatches directly (used by [LocalCoordinatorChannel]).
  Future<Object?> handle(String service, String op, Map<String, Object?> args) {
    try {
      final result = _invoke(service, op, args);
      return result is Future<Object?> ? result : Future<Object?>.value(result);
    } on Object catch (error, stackTrace) {
      return Future<Object?>.error(error, stackTrace);
    }
  }

  FutureOr<Object?> _invoke(
    String service,
    String op,
    Map<String, Object?> args,
  ) {
    final target = _services[service];
    if (target == null) {
      throw CoordinatorException('Unknown coordinator service [$service].');
    }
    _handled++;
    return target.handle(op, args);
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
      _inFlight++;
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
      'services': <String, Object?>{
        for (final entry in _services.entries) entry.key: entry.value.stats(),
      },
    };
  }

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

  Future<Object?> call(
    String service,
    String op,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 1),
  });
}

/// Direct in-process calls (single isolate / tests): no message hop.
final class LocalCoordinatorChannel implements CoordinatorChannel {
  const LocalCoordinatorChannel(this.coordinator);

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
}

/// Request/response over [SendPort] with correlation ids and timeouts.
final class RemoteCoordinatorChannel implements CoordinatorChannel {
  RemoteCoordinatorChannel(this._target) {
    _replies = ReceivePort('daravel-coordinator-client');
    _replies.listen(_onReply);
  }

  final SendPort _target;
  late final ReceivePort _replies;
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

  int get pending => _pending.length;

  @override
  Future<Object?> call(
    String service,
    String op,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 1),
  }) {
    if (_closed) {
      // After close() no reply can arrive: fail now rather than after the
      // timeout (and without restarting the sweeper).
      return Future<Object?>.error(
        const CoordinatorException('Coordinator channel closed.'),
      );
    }
    final id = _nextId++;
    final call = _PendingCall(
      service,
      timeout,
      _clock.elapsedMicroseconds + timeout.inMicroseconds,
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
    final error = message.error;
    if (error != null) {
      call.completer.completeError(CoordinatorException(error));
    } else {
      call.completer.complete(message.result);
    }
  }

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
  _PendingCall(this.service, this.timeout, this.deadline);

  final String service;
  final Duration timeout;

  /// Monotonic microseconds after which the call times out.
  final int deadline;
  final Completer<Object?> completer = Completer<Object?>();
}
