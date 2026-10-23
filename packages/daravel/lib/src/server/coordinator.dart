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

  void register(CoordinatorService service) =>
      _services[service.name] = service;

  CoordinatorService? service(String name) => _services[name];

  Iterable<String> get serviceNames => _services.keys;

  /// Dispatches directly (used by [LocalCoordinatorChannel]).
  Future<Object?> handle(
    String service,
    String op,
    Map<String, Object?> args,
  ) async {
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
        message.replyTo.send(
          CoordinatorReply(message.id, error: 'Coordinator queue is full.'),
        );
        return;
      }
      _inFlight++;
      unawaited(_dispatch(message));
    });
    return port.sendPort;
  }

  Future<void> _dispatch(CoordinatorRequest request) async {
    try {
      final result = await handle(request.service, request.op, request.args);
      request.replyTo.send(CoordinatorReply(request.id, result: result));
    } catch (error) {
      request.replyTo.send(CoordinatorReply(request.id, error: '$error'));
    } finally {
      _inFlight--;
    }
  }

  Map<String, Object?> stats() => <String, Object?>{
    'handled': _handled,
    'rejected': _rejected,
    'in_flight': _inFlight,
    'services': <String, Object?>{
      for (final entry in _services.entries) entry.key: entry.value.stats(),
    },
  };

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
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};
  int _nextId = 0;

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
    final id = _nextId++;
    final completer = Completer<Object?>();
    _pending[id] = completer;
    _target.send(
      CoordinatorRequest(
        id: id,
        service: service,
        op: op,
        args: args,
        replyTo: _replies.sendPort,
      ),
    );
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        _pending.remove(id);
        throw CoordinatorTimeoutException(service, timeout);
      },
    );
  }

  void _onReply(Object? message) {
    if (message is! CoordinatorReply) {
      return;
    }
    final completer = _pending.remove(message.id);
    if (completer == null) {
      return;
    }
    final error = message.error;
    if (error != null) {
      completer.completeError(CoordinatorException(error));
    } else {
      completer.complete(message.result);
    }
  }

  void close() {
    _replies.close();
    for (final completer in _pending.values) {
      completer.completeError(
        const CoordinatorException('Coordinator channel closed.'),
      );
    }
    _pending.clear();
  }
}
