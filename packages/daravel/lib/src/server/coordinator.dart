import 'dart:async';
import 'dart:collection';
import 'dart:isolate';

import 'package:meta/meta.dart';

import '../foundation/detached.dart';
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
    this.deadline = 0,
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

  /// When the caller stops waiting, in microseconds since the epoch (wall
  /// clock, which every isolate of the process shares); 0 for never. Set
  /// for an [ExpiringCoordinatorMessage]: the coordinator drops such a
  /// request unanswered once it has passed, instead of doing work nobody
  /// waits for any more.
  final int deadline;
}

/// The kinds of failure a [CoordinatorReply] reports, as small integers
/// (sent between isolates as they are).
abstract final class CoordinatorErrorKind {
  /// No error.
  static const int none = 0;

  /// The service failed ([CoordinatorException]).
  static const int failed = 1;

  /// The call was refused because the coordinator is saturated
  /// ([CoordinatorOverloaded]).
  static const int overloaded = 2;

  /// The coordinator's queue was full ([CoordinatorException]).
  static const int queueFull = 3;
}

/// Bulk calls of one worker sent as one message (Blueprint #141 K1b): the
/// calls its credit window held back, sent together once credit came back.
/// Each is served as if sent alone; the answers that are ready at once come
/// back together in one [CoordinatorBatchReply].
final class CoordinatorBatch {
  /// [requests], answered on [replyTo].
  const CoordinatorBatch(this.requests, this.replyTo);

  /// The calls, in the order the worker made them.
  final List<CoordinatorRequest> requests;

  /// Where the replies go.
  final SendPort replyTo;
}

/// The answers to the calls of a [CoordinatorBatch] that were ready at
/// once; the others come later, each in a [CoordinatorReply].
final class CoordinatorBatchReply {
  /// [replies], in the batch's order.
  const CoordinatorBatchReply(this.replies);

  /// The answers.
  final List<CoordinatorReply> replies;
}

/// A worker's first message (sent once, when its channel opens): where
/// health announcements go, so the coordinator does not have to learn its
/// peers from every request.
final class CoordinatorHello {
  /// A worker whose replies arrive on [replyTo].
  const CoordinatorHello(this.replyTo);

  /// The worker's reply port.
  final SendPort replyTo;
}

/// Reply to a [CoordinatorRequest].
final class CoordinatorReply {
  /// The reply to call [id]: a [result] or an [error].
  const CoordinatorReply(
    this.id, {
    this.result,
    this.error,
    this.errorKind = CoordinatorErrorKind.none,
  });

  /// What kind of failure [error] is ([CoordinatorErrorKind]): what the
  /// caller's exception is chosen by; [error] is only for people.
  final int errorKind;

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

/// A [CoordinatorMessage] the coordinator may drop, unanswered, once its
/// caller has stopped waiting for it (#148): a [RemoteCoordinatorChannel]
/// sends it with the call's deadline, and a request still queued after that
/// deadline is not handled (`coordinator_expired_total`). Only for
/// operations whose effect nobody needs once the caller gave up: a lock
/// acquisition or a rate-limit attempt that the worker already treated as
/// failed, never a release.
abstract interface class ExpiringCoordinatorMessage
    implements CoordinatorMessage {
  /// Whether this message is dropped once its deadline has passed.
  bool get expiresWithCall;
}

/// How a coordinator service's calls are served when the coordinator falls
/// behind (Blueprint #141, K1): [critical] always at once, [normal] put off
/// while it is [CoordinatorState.saturated], [bulk] put off while it is
/// [CoordinatorState.lagging] and refused while it is saturated.
enum CoordinatorPriority {
  /// Locks, rate limits, the JWT denylist: answered at once, always.
  critical,

  /// The `process` cache, presence channels, and any service that does
  /// not say: put off while saturated, still answered.
  normal,

  /// Broadcast fan-out, metrics, worker reports: put off while lagging,
  /// refused ([CoordinatorOverloaded]) while saturated. Only for calls
  /// whose loss is harmless (telemetry); a service opts in.
  bulk,
}

/// A [CoordinatorService] that says how urgent its calls are; a service
/// that does not is [CoordinatorPriority.normal] (put off while the
/// coordinator is saturated, never refused). Mix it in (or implement
/// it): [priorityFor] answers [priority] unless a service tells its calls
/// apart (the `process` cache's locks are critical, its reads normal).
abstract mixin class PrioritizedService {
  /// How the service's calls are served when the coordinator falls behind;
  /// a service whose [priority] is [CoordinatorPriority.bulk] is the one
  /// workers stop calling while it is saturated.
  CoordinatorPriority get priority;

  /// The operations that are bulk whatever [priority] says (a publish, a
  /// periodic report): put off while the coordinator lags, refused while
  /// it is saturated, and failed at once then by the workers, which hear
  /// them named in its announcements. The rest of the service (reads,
  /// subscriptions, the scrape of `/metrics`) keeps [priority].
  Set<String> get bulkOperations => const <String>{};

  /// The priority of one call ([op] and [args], a map or a typed message).
  CoordinatorPriority priorityFor(String op, Object args) =>
      bulkOperations.contains(op) ? CoordinatorPriority.bulk : priority;
}

/// How far behind the coordinator is, from how late its event loop runs
/// a timer (its queue lag).
enum CoordinatorState {
  /// The lag is under the warning threshold.
  healthy,

  /// The lag has been at or above the warning threshold for three
  /// measurements in a row: [CoordinatorPriority.bulk] calls wait.
  lagging,

  /// The lag is at or above the shedding threshold, or the queue of calls
  /// put off is full: [CoordinatorPriority.bulk] calls are refused.
  saturated,
}

/// What a coordinator tells its workers when its [CoordinatorState]
/// changes (and each second while it is not healthy), so a worker stops
/// waiting on calls the coordinator would refuse (Blueprint #141, K1).
@pragma('vm:deeply-immutable')
final class CoordinatorHealth implements CoordinatorMessage {
  /// The coordinator is in [state] ([CoordinatorState.index]) with
  /// [lagMicros] of queue lag; [epoch] counts the announcements; and
  /// [shedServices] (comma-separated) are refused while saturated.
  const CoordinatorHealth(
    this.state,
    this.lagMicros,
    this.epoch,
    this.shedServices,
  );

  /// [CoordinatorState.index].
  final int state;

  /// The last queue lag measured, in microseconds.
  final int lagMicros;

  /// Increases with each announcement.
  final int epoch;

  /// The services the coordinator refuses while saturated.
  final String shedServices;
}

/// A call the coordinator refused because it is saturated, or that the
/// worker did not send because the coordinator said so (or because its bulk
/// buffer was full).
///
/// It means "back off or drop": catch it and do something else, never call
/// again at once in a loop. A refusal decided in the worker arrives on the
/// next turn of the event loop, not at once, so even such a loop lets the
/// isolate's timers and sockets run.
final class CoordinatorOverloaded extends CoordinatorException {
  /// A refused call to [service].
  const CoordinatorOverloaded(String service)
    : super('Coordinator overloaded: [$service] calls are shed.');
}

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
  /// A coordinator queueing at most [maxQueue] calls. It is
  /// [CoordinatorState.lagging] once its queue lag stays at or above
  /// [lagWarn] for three measurements, and [CoordinatorState.saturated] at
  /// [lagShed] or with [maxQueue] calls put off.
  Coordinator({
    this.maxQueue = 10000,
    this.lagWarn = const Duration(milliseconds: 5),
    this.lagShed = const Duration(milliseconds: 50),
    this.probeEvery = lagProbeInterval,
    this.timerSlack = defaultTimerSlack,
  });

  /// How late the probe's timer may fire without the loop being behind
  /// ([defaultTimerSlack]; another only in tests).
  final Duration timerSlack;

  /// How often [listen]'s lag probe measures the event loop
  /// ([lagProbeInterval]); a test that feeds [observeLag] itself gives a
  /// long one.
  final Duration probeEvery;

  /// Pending requests above this count are rejected (backpressure); also
  /// the most calls put off at once.
  final int maxQueue;

  /// The queue lag at which the coordinator is lagging
  /// (`COORDINATOR_LAG_WARN_MS`).
  final Duration lagWarn;

  /// The queue lag at which it is saturated (`COORDINATOR_LAG_SHED_MS`).
  final Duration lagShed;

  CoordinatorState _state = CoordinatorState.healthy;
  int _lagWarnings = 0;
  int _calm = 0;
  int _belowShed = 0;

  /// Lag measurements in a row under a threshold before the state improves.
  static const int recoverySamples = 3;
  int _epoch = 0;
  int _unhealthyProbes = 0;

  /// Calls put off, one queue per class: normal ones are served first, and
  /// each class keeps its order (ACK 238, Addendum 1).
  final ListQueue<CoordinatorRequest> _deferredNormal =
      ListQueue<CoordinatorRequest>();
  final ListQueue<CoordinatorRequest> _deferredBulk =
      ListQueue<CoordinatorRequest>();
  int _deferredPeak = 0;

  /// Calls taken off the port and dealt with (served, put off, refused),
  /// each call of a batch and of the queues put off counted: the evidence
  /// of a queue the lag probe weighs ([queueEvidence]).
  int _callsHandled = 0;
  bool _draining = false;
  final Map<String, int> _shed = <String, int>{};
  final List<int> _byPriority = List<int>.filled(
    CoordinatorPriority.values.length,
    0,
  );

  /// The workers' reply ports: where health announcements go.
  final Set<SendPort> _peers = <SendPort>{};

  /// The most peers remembered; past it the set starts over (dead
  /// isolates' ports would otherwise only accumulate).
  static const int maxPeers = 4096;

  /// How far behind the coordinator is.
  CoordinatorState get state => _state;

  /// Calls dealt with so far, each call of a batch and of the queues put
  /// off counted (the probe's evidence of a queue).
  @visibleForTesting
  int get callsHandled => _callsHandled;

  /// Calls put off now.
  int get deferred => _deferredNormal.length + _deferredBulk.length;

  final Map<String, CoordinatorService> _services =
      <String, CoordinatorService>{};
  RawReceivePort? _port;
  int _inFlight = 0;
  int _peakInFlight = 0;
  int _handled = 0;
  int _rejected = 0;
  int _expired = 0;

  /// Messages taken off the port: a batch is one, however many calls it
  /// holds (K1b); `messages` in [stats] counts calls.
  int _portMessages = 0;

  /// The lag probe's last measurement, and the largest: how long a message
  /// waits behind the others in the coordinator's event loop, synchronous
  /// services included ([_probeLag]).
  Duration _lag = Duration.zero;
  Duration _lagPeak = Duration.zero;
  Timer? _lagProbe;

  /// How often [listen]'s lag probe measures the event loop.
  static const Duration lagProbeInterval = Duration(milliseconds: 100);

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
    // A raw port: no stream machinery between the message and the
    // dispatch, on the path every throttled request takes.
    final port = RawReceivePort(null, 'daravel-coordinator');
    _port = port;
    _probeLag();
    port.handler = (Object? message) {
      _portMessages++;
      switch (message) {
        case final CoordinatorRequest request:
          _onRequest(request);
        case final CoordinatorBatch batch:
          _onBatch(batch);
        case CoordinatorHello(:final replyTo):
          // Known once, when its channel opens, not from every request
          // (a SendPort hash per message on the hottest path). A worker
          // first heard from while the coordinator is not healthy is told
          // at once, before any reply.
          if (_peers.length >= maxPeers) {
            _peers.clear();
          }
          if (_peers.add(replyTo) && _state != CoordinatorState.healthy) {
            _tell(replyTo, _health());
          }
      }
    };
    return port.sendPort;
  }

  void _onRequest(CoordinatorRequest message) {
    _callsHandled++;
    if (_expiredNow(message)) {
      return;
    }
    // Healthy, nothing put off: no priority to work out (served as it
    // comes).
    if (_state == CoordinatorState.healthy && deferred == 0) {
      _serve(message, null);
      return;
    }
    final priority = _priorityOfCall(message);
    switch (priority) {
      case CoordinatorPriority.critical:
        // Never put off, never refused.
        _serve(message, priority);
      case CoordinatorPriority.bulk when _state == CoordinatorState.saturated:
        _refuse(message);
      case CoordinatorPriority.bulk
          when _state == CoordinatorState.lagging || _deferredBulk.isNotEmpty:
        // Behind the bulk calls already put off, whatever the state now:
        // one worker's bulk calls keep their order (ACK 235, Addendum 2
        // B.6).
        _defer(message, priority);
      case CoordinatorPriority.normal
          when _state == CoordinatorState.saturated ||
              _deferredNormal.isNotEmpty:
        // Behind the normal calls put off (after a saturation); never
        // behind bulk calls alone (ACK 238).
        _defer(message, priority);
      case _:
        _serve(message, priority);
    }
  }

  /// A worker's bulk calls sent together (K1b). Each is served as if sent
  /// alone; the answers ready at once go back in one
  /// [CoordinatorBatchReply], the others each in its own reply later.
  void _onBatch(CoordinatorBatch batch) {
    final ready = <CoordinatorReply>[];
    for (final message in batch.requests) {
      _callsHandled++;
      if (_expiredNow(message)) {
        continue;
      }
      if (_state == CoordinatorState.saturated) {
        _shed[message.service] = (_shed[message.service] ?? 0) + 1;
        ready.add(
          CoordinatorReply(
            message.id,
            error: CoordinatorOverloaded(message.service).message,
            errorKind: CoordinatorErrorKind.overloaded,
          ),
        );
        continue;
      }
      // Behind the bulk calls already put off too, so the order holds.
      if (_state == CoordinatorState.lagging || _deferredBulk.isNotEmpty) {
        _defer(message, CoordinatorPriority.bulk);
        continue;
      }
      _serve(message, CoordinatorPriority.bulk, into: ready);
    }
    if (ready.isEmpty) {
      return;
    }
    try {
      batch.replyTo.send(CoordinatorBatchReply(ready));
    } on Object {
      // A result that cannot cross an isolate: each on its own, so the
      // others still arrive and that one gets its error ([_reply]).
      for (final reply in ready) {
        final request = batch.requests.firstWhere((r) => r.id == reply.id);
        _reply(request, reply);
      }
    }
  }

  /// Whether [message] is an [ExpiringCoordinatorMessage] whose caller has
  /// given up on it (counted as expired): answering would only be work (a
  /// lock taken, a hit counted) nobody waits for.
  bool _expiredNow(CoordinatorRequest message) {
    final args = message.args;
    if (message.deadline != 0 &&
        args is ExpiringCoordinatorMessage &&
        args.expiresWithCall &&
        DateTime.now().microsecondsSinceEpoch > message.deadline) {
      _expired++;
      return true;
    }
    return false;
  }

  /// The priority of [service]: its own ([PrioritizedService]), else
  /// [CoordinatorPriority.normal].
  CoordinatorPriority priorityOf(String service) =>
      switch (_services[service]) {
        final PrioritizedService prioritized => prioritized.priority,
        _ => CoordinatorPriority.normal,
      };

  /// The priority of one call: its service's
  /// [PrioritizedService.priorityFor].
  CoordinatorPriority _priorityOfCall(CoordinatorRequest message) =>
      switch (_services[message.service]) {
        final PrioritizedService prioritized => prioritized.priorityFor(
          message.op,
          message.args,
        ),
        _ => CoordinatorPriority.normal,
      };

  /// Refuses [message] with [CoordinatorOverloaded] (counted per service).
  void _refuse(CoordinatorRequest message) {
    _shed[message.service] = (_shed[message.service] ?? 0) + 1;
    _reply(
      message,
      CoordinatorReply(
        message.id,
        error: CoordinatorOverloaded(message.service).message,
        errorKind: CoordinatorErrorKind.overloaded,
      ),
    );
  }

  /// Puts [message] off, to be served between incoming messages; a full
  /// queue makes the coordinator saturated and refuses it.
  void _defer(CoordinatorRequest message, CoordinatorPriority priority) {
    if (deferred >= maxQueue) {
      _setState(CoordinatorState.saturated);
      if (priority == CoordinatorPriority.bulk) {
        _refuse(message);
      } else {
        _rejected++;
        _reply(
          message,
          CoordinatorReply(
            message.id,
            error: 'Coordinator queue is full.',
            errorKind: CoordinatorErrorKind.queueFull,
          ),
        );
      }
      return;
    }
    final queue = priority == CoordinatorPriority.normal
        ? _deferredNormal
        : _deferredBulk;
    queue.add(message);
    if (deferred > _deferredPeak) {
      _deferredPeak = deferred;
    }
    // Catch up two for one: a call joining the tail lets two be served
    // from the head of its class when the state allows it, so a queue fed
    // without pause (a closed system: credit back, new bulk calls) still
    // empties, in order (ACK 238, Addendum 1). Only once healthy again:
    // while lagging or saturated the calls stay put off.
    if (_state == CoordinatorState.healthy) {
      for (var i = 0; i < 2 && queue.isNotEmpty; i++) {
        _serveDeferred(queue.removeFirst());
      }
    }
    if (deferred > 0 && !_draining) {
      _draining = true;
      Timer.run(_drain);
    }
  }

  /// Serves [message], taken off a queue of calls put off: refused instead
  /// when it is bulk and the coordinator saturated.
  void _serveDeferred(CoordinatorRequest message) {
    _callsHandled++;
    if (_expiredNow(message)) {
      return;
    }
    final priority = _priorityOfCall(message);
    if (_state == CoordinatorState.saturated &&
        priority == CoordinatorPriority.bulk) {
      _refuse(message);
      return;
    }
    _serve(message, priority);
  }

  /// Serves up to [drainBatch] calls put off, normal ones first, then lets
  /// the messages that arrived meanwhile through before the next batch.
  void _drain() {
    var served = 0;
    while (deferred > 0 && served < drainBatch) {
      served++;
      _serveDeferred(
        _deferredNormal.isNotEmpty
            ? _deferredNormal.removeFirst()
            : _deferredBulk.removeFirst(),
      );
    }
    if (deferred > 0) {
      Timer.run(_drain);
      return;
    }
    _draining = false;
  }

  /// Calls put off that are served in one turn of the event loop.
  static const int drainBatch = 64;

  /// While healthy, one served call in this many is classified by priority
  /// for [stats] (`served_by_priority`, counted for all of them): working
  /// out every call's priority cost the healthy path a lookup and a
  /// virtual call per message (Review K1, ACK 225).
  static const int classifyEvery = 16;
  int _unclassified = 0;

  /// Serves [message], of [priority] when it was worked out (not on the
  /// healthy path, where served calls are classified for [stats] one in
  /// [classifyEvery] only). A synchronous answer goes into [into] when
  /// given (a batch's reply), else back at once.
  void _serve(
    CoordinatorRequest message,
    CoordinatorPriority? priority, {
    List<CoordinatorReply>? into,
  }) {
    if (priority != null) {
      _byPriority[priority.index]++;
    } else if (++_unclassified == classifyEvery) {
      _unclassified = 0;
      _byPriority[_priorityOfCall(message).index] += classifyEvery;
    }
    if (_inFlight >= maxQueue) {
      _rejected++;
      _reply(
        message,
        CoordinatorReply(
          message.id,
          error: 'Coordinator queue is full.',
          errorKind: CoordinatorErrorKind.queueFull,
        ),
      );
      return;
    }
    // Synchronous services (rate limits, memory cache, locks) answer
    // inline: no Future or microtask per message.
    final FutureOr<Object?> result;
    try {
      result = _invoke(message.service, message.op, message.args);
    } on Object catch (error) {
      final reply = CoordinatorReply(
        message.id,
        error: '$error',
        errorKind: CoordinatorErrorKind.failed,
      );
      into == null ? _reply(message, reply) : into.add(reply);
      return;
    }
    if (result is! Future<Object?>) {
      final reply = CoordinatorReply(message.id, result: result);
      if (into != null) {
        into.add(reply);
        return;
      }
      _reply(message, reply);
      return;
    }
    if (++_inFlight > _peakInFlight) {
      _peakInFlight = _inFlight;
    }
    unawaited(_dispatch(message, result));
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
          errorKind: CoordinatorErrorKind.failed,
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
      _reply(
        request,
        CoordinatorReply(
          request.id,
          error: '$error',
          errorKind: CoordinatorErrorKind.failed,
        ),
      );
    } finally {
      _inFlight--;
    }
  }

  /// Measures the coordinator's queue lag every [probeEvery] while
  /// listening, which [maxQueue] does not see for synchronous services.
  /// When the probe's timer fires it sends a message to the coordinator's
  /// own isolate: the time until it is handled is how long a message waits
  /// behind those queued before it. How late the timer fired counts too,
  /// past [timerSlack], for one long call that blocks the loop with nothing
  /// queued behind it.
  void _probeLag() {
    // One port, kept: the probe's message goes to it each time.
    final probe = _probePort ??= RawReceivePort(
      null,
      'daravel-coordinator-probe',
    );
    final watch = Stopwatch()..start();
    _lagProbe = Timer(probeEvery, () {
      final late = watch.elapsed - probeEvery;
      final sent = Stopwatch()..start();
      final handledBefore = _callsHandled;
      probe.handler = (Object? _) {
        final waited = sent.elapsed;
        final handled = _callsHandled - handledBefore;
        _observeStarvation(starvationOf(late, waited, handled, timerSlack));
        observeLag(lagOf(waited, handled));
        if (_port != null) {
          _probeLag();
        }
      };
      probe.sendPort.send(null);
    });
  }

  RawReceivePort? _probePort;

  /// How many calls the coordinator must have dealt with while the probe
  /// waited (each call of a batch and of the queues put off counted) for
  /// its wait to count as a queue (Blueprint #141 §6.6): a long
  /// wait with fewer handled means the isolate was not scheduled (a busy
  /// host, a GC pause, a sleeping machine), which refusing work would not
  /// help. 16: a few workers' bursts, well above the one or two messages
  /// an idle server handles in 100 ms, well below a flood.
  static const int queueEvidence = 16;

  /// The last and largest wait that was not a queue ([starvationOf]): the
  /// isolate starved of CPU, or a timer late (`coordinator_starved_ms`).
  Duration _starved = Duration.zero;
  Duration _starvedPeak = Duration.zero;

  void _observeStarvation(Duration starved) {
    _starved = starved;
    if (starved > _starvedPeak) {
      _starvedPeak = starved;
    }
  }

  /// How late a timer may fire without the loop being behind: the
  /// coarsest timer resolution of a supported system. Windows' default
  /// timer resolution is 15.6 ms; measured on Windows 11 (2026-11-10), an
  /// idle 100 ms timer fired 4.8 to 8.3 ms late (median 7.0, 30 samples),
  /// which the probe would otherwise have read as lag.
  static const Duration defaultTimerSlack = Duration(milliseconds: 16);

  /// One probe's queue lag, what the state follows: how long its message
  /// waited ([waited]), when the coordinator handled at least
  /// [queueEvidence] other messages meanwhile ([handled]); zero otherwise.
  @visibleForTesting
  static Duration lagOf(Duration waited, int handled) =>
      handled >= queueEvidence ? waited : Duration.zero;

  /// One probe's wait that was not a queue, for metrics only: the wait
  /// with fewer than [queueEvidence] messages handled, or how late its
  /// timer fired ([timerLate]) past [slack] (one long call blocking the
  /// loop), whichever is larger.
  @visibleForTesting
  static Duration starvationOf(
    Duration timerLate,
    Duration waited,
    int handled,
    Duration slack,
  ) {
    final late = timerLate - slack;
    final idle = handled < queueEvidence ? waited : Duration.zero;
    return late > idle ? late : idle;
  }

  /// Takes one measurement of the queue lag, [lag]: what the probe does
  /// every [probeEvery]. A test gives the lag it wants instead of blocking
  /// the event loop.
  @visibleForTesting
  void observeLag(Duration lag) {
    _lag = lag;
    if (_lag > _lagPeak) {
      _lagPeak = _lag;
    }
    _assess();
  }

  /// The state after one lag measurement. Worse at once: saturated at
  /// [lagShed] (or a full queue of calls put off), lagging after three
  /// measurements at [lagWarn]. Better only after [recoverySamples]
  /// measurements in a row under the threshold (hysteresis: no flapping on
  /// a lag that hovers at one). An unhealthy state is announced again each
  /// second.
  void _assess() {
    final shedding = _lag >= lagShed || deferred >= maxQueue;
    if (_lag >= lagWarn) {
      _lagWarnings++;
      _calm = 0;
    } else {
      _lagWarnings = 0;
      _calm++;
    }
    _belowShed = shedding ? 0 : _belowShed + 1;
    final CoordinatorState next;
    if (shedding) {
      next = CoordinatorState.saturated;
    } else if (_state == CoordinatorState.saturated &&
        _belowShed < recoverySamples) {
      // Saturated stays until recoverySamples measurements in a row below
      // it, checked before calm: a saturation from a full queue of calls
      // put off, with a low lag, would otherwise turn healthy at once and
      // swing with every message (ACK 235, Addendum 2 B.5).
      next = CoordinatorState.saturated;
    } else if (_calm >= recoverySamples) {
      // Healthy even with calls still put off: in a closed system their
      // queue never empties while traffic flows, and they keep their order
      // anyway (each class's queue, two served per call joining it).
      next = CoordinatorState.healthy;
    } else if (_lagWarnings >= 3 || _state != CoordinatorState.healthy) {
      next = CoordinatorState.lagging;
    } else {
      next = CoordinatorState.healthy;
    }
    if (next != _state) {
      _setState(next);
      return;
    }
    if (_state != CoordinatorState.healthy &&
        ++_unhealthyProbes * probeEvery.inMicroseconds >= 1000000) {
      _announce();
    }
  }

  void _setState(CoordinatorState next) {
    if (next == _state) {
      return;
    }
    _state = next;
    if (next != CoordinatorState.saturated && deferred > 0 && !_draining) {
      _draining = true;
      Timer.run(_drain);
    }
    _announce();
  }

  /// Tells every worker the coordinator heard from its [state].
  void _announce() {
    _unhealthyProbes = 0;
    final health = _health();
    for (final peer in _peers) {
      _tell(peer, health);
    }
  }

  CoordinatorHealth _health() => CoordinatorHealth(
    _state.index,
    _lag.inMicroseconds,
    ++_epoch,
    [
      for (final MapEntry(key: name, value: service) in _services.entries)
        if (priorityOf(name) == CoordinatorPriority.bulk)
          name
        else if (service case final PrioritizedService prioritized)
          for (final op in prioritized.bulkOperations) '$name.$op',
    ].join(','),
  );

  static void _tell(SendPort peer, CoordinatorHealth health) {
    try {
      peer.send(health);
    } on Object {
      // A closed port: nothing to tell.
    }
  }

  /// Counters, the message rate and each service's snapshot. `messages`
  /// (handled plus rejected) only grows; with `uptime_s`, or by reading the
  /// stats twice, it shows a flood of messages from the workers, which the
  /// coordinator answers on the supervisor's own event loop.
  Map<String, Object?> stats() {
    final messages = _handled + _rejected + _expired;
    final seconds = _uptime.elapsedMicroseconds / 1e6;
    return <String, Object?>{
      'handled': _handled,
      'rejected': _rejected,
      // Requests dropped unanswered because their caller had stopped
      // waiting (an [ExpiringCoordinatorMessage] past its deadline).
      'expired': _expired,
      'messages': messages,
      'port_messages': _portMessages,
      'uptime_s': double.parse(seconds.toStringAsFixed(1)),
      'messages_per_second': seconds == 0
          ? 0.0
          : double.parse((messages / seconds).toStringAsFixed(1)),
      'in_flight': _inFlight,
      // How close the asynchronous calls came to [maxQueue], where calls
      // start to be refused.
      'in_flight_peak': _peakInFlight,
      'max_queue': maxQueue,
      // How long a message waits in the event loop (the lag probe): the
      // backlog of synchronous services, which never count in in_flight.
      // Since K1, the wait of a message to the coordinator itself, or the
      // probe timer's lateness past timerSlack (before: the timer's
      // lateness alone, several ms on an idle Windows loop).
      'queue_lag_ms': _lag.inMicroseconds / 1000,
      'queue_lag_peak_ms': _lagPeak.inMicroseconds / 1000,
      // Waits that were not a queue (a busy host, a late timer): shown,
      // never a reason to refuse work (§6.6).
      'starved_ms': _starved.inMicroseconds / 1000,
      'starved_peak_ms': _starvedPeak.inMicroseconds / 1000,
      // Blueprint #141 K1: health, calls put off, and calls refused.
      'state': _state.name,
      'deferred': deferred,
      'deferred_peak': _deferredPeak,
      'shed': <String, Object?>{..._shed},
      'served_by_priority': <String, Object?>{
        for (final p in CoordinatorPriority.values)
          p.name: _byPriority[p.index],
      },
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
    _lagProbe?.cancel();
    _lagProbe = null;
    _probePort?.close();
    _probePort = null;
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
  /// A channel to a coordinator in another isolate, holding at most
  /// [bulkWindow] bulk calls unanswered and [bulkBuffer] more waiting
  /// ([sendBulk]).
  RemoteCoordinatorChannel(
    this._target, {
    this.bulkWindow = defaultBulkWindow,
    this.bulkBuffer = defaultBulkBuffer,
  }) {
    _replies = ReceivePort('daravel-coordinator-client');
    _replies.listen(_onReply);
    // Known to the coordinator once, for its health announcements.
    _target.send(CoordinatorHello(_replies.sendPort));
  }

  final SendPort _target;
  late final ReceivePort _replies;

  /// The bulk calls one worker may have unanswered at once (Blueprint #141
  /// K1b): what bounds the coordinator's port, which priorities cannot
  /// reorder, at workers × this many bulk messages.
  final int bulkWindow;

  /// The bulk calls one worker keeps waiting for credit, sent together
  /// when credit comes back; past it [BulkOverflow] decides.
  final int bulkBuffer;

  /// [bulkWindow] by default.
  static const int defaultBulkWindow = 16;

  /// [bulkBuffer] by default.
  static const int defaultBulkBuffer = 1024;

  int _bulkInFlight = 0;
  final ListQueue<_BufferedBulk> _bulkWaiting = ListQueue<_BufferedBulk>();
  int _bulkDropped = 0;
  int _bulkBatches = 0;

  /// Receives the service of each bulk call dropped or refused because the
  /// buffer was full.
  void Function(String service, BulkOverflow overflow)? onBulkOverflow;

  /// Bulk calls waiting for credit now.
  int get bulkWaiting => _bulkWaiting.length;

  /// Bulk calls sent and not answered yet.
  int get bulkInFlight => _bulkInFlight;

  /// Bulk calls dropped or refused by a full buffer, and the batches sent.
  ({int dropped, int batches}) get bulkStats =>
      (dropped: _bulkDropped, batches: _bulkBatches);

  /// Calls [op] on [service] as a bulk call (broadcast fan-out, metrics,
  /// worker reports, records): sent at once while fewer than [bulkWindow]
  /// are unanswered, else kept, in order, until credit comes back (a reply,
  /// or a call's timeout), then sent with the others waiting as one
  /// [CoordinatorBatch]. Ordering holds between the bulk calls of this
  /// channel, not against its other calls. A full buffer applies
  /// [overflow]. The timeout counts from this call, in the buffer too.
  Future<Object?> sendBulk(
    String service,
    String op,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 1),
    BulkOverflow overflow = BulkOverflow.refuse,
  }) {
    if (shortCircuits(service, op)) {
      return _refuseOnNextTurn(shortCircuit(service));
    }
    if (_closed) {
      return Future<Object?>.error(
        const CoordinatorException('Coordinator channel closed.'),
      );
    }
    if (_bulkInFlight < bulkWindow && _bulkWaiting.isEmpty) {
      _bulkInFlight++;
      return _send(service, op, args, timeout, bulk: true);
    }
    if (_bulkWaiting.length >= bulkBuffer) {
      _bulkDropped++;
      onBulkOverflow?.call(service, overflow);
      if (overflow == BulkOverflow.refuse) {
        return _refuseOnNextTurn(CoordinatorOverloaded(service));
      }
      final oldest = _bulkWaiting.removeFirst();
      // Its caller is told on the next turn too: two senders dropping each
      // other's oldest call would otherwise take turns in microtasks.
      _failOnNextTurn(oldest.completer, CoordinatorOverloaded(oldest.service));
    }
    final waiting = _BufferedBulk(
      service,
      op,
      args,
      timeout,
      _clock.elapsedMicroseconds + timeout.inMicroseconds,
    );
    _bulkWaiting.add(waiting);
    _startSweeper();
    return waiting.completer.future;
  }

  /// A bulk credit back (a reply, or a timeout). What waits is sent once
  /// half the window is free (or nothing is in flight), as one batch: a
  /// call per credit would send as many messages as before.
  void _creditBack() {
    if (_bulkInFlight > 0) {
      _bulkInFlight--;
    }
    if (_bulkInFlight == 0 || bulkWindow - _bulkInFlight >= _refillAt) {
      _sendWaiting();
    }
  }

  int get _refillAt => bulkWindow < 2 ? 1 : bulkWindow ~/ 2;

  /// Sends as many waiting bulk calls as there is credit for: one as it
  /// is, several as one [CoordinatorBatch].
  void _sendWaiting() {
    if (_closed || _bulkWaiting.isEmpty) {
      return;
    }
    final now = _clock.elapsedMicroseconds;
    final requests = <CoordinatorRequest>[];
    while (_bulkInFlight < bulkWindow && _bulkWaiting.isNotEmpty) {
      final waiting = _bulkWaiting.removeFirst();
      if (now >= waiting.deadline) {
        waiting.completer.completeError(
          CoordinatorTimeoutException(waiting.service, waiting.timeout),
        );
        onCallTimeout?.call(waiting.service);
        continue;
      }
      // Refused now rather than sent to be refused (ACK 238, Addendum 1).
      if (shortCircuits(waiting.service, waiting.op)) {
        waiting.completer.completeError(shortCircuit(waiting.service));
        continue;
      }
      final id = _nextId++;
      _pending[id] = _PendingCall(
        waiting.service,
        waiting.timeout,
        waiting.deadline,
        now,
        bulk: true,
        completer: waiting.completer,
      );
      _bulkInFlight++;
      requests.add(
        CoordinatorRequest(
          id: id,
          service: waiting.service,
          op: waiting.op,
          args: waiting.args,
          replyTo: _replies.sendPort,
        ),
      );
    }
    if (requests.isEmpty) {
      return;
    }
    if (requests.length == 1) {
      _target.send(requests.single);
    } else {
      _bulkBatches++;
      _target.send(CoordinatorBatch(requests, _replies.sendPort));
    }
  }

  /// Completes once no bulk call waits or is unanswered (each answered,
  /// refused or timed out), or after [timeout]: what a worker does on
  /// `Stop`, before it says it exited, so its last reports reach the
  /// coordinator.
  Future<void> flush({Duration timeout = const Duration(seconds: 2)}) async {
    final deadline = DateTime.now().add(timeout);
    while ((_bulkWaiting.isNotEmpty || _bulkInFlight > 0) &&
        !_closed &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

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
  Detached<Timer>? _sweeper;

  /// Starts the timeout sweep, once, outside the request or job whose call
  /// starts it: it lives as long as calls are pending, not as long as that
  /// request (Review #149).
  void _startSweeper() => _sweeper ??= runDetached(
    () => Timer.periodic(sweepInterval, (_) => _sweep()),
    name: 'coordinator call timeouts',
  );

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
    Duration timeout, {
    bool bulk = false,
  }) {
    // The coordinator refuses this service while saturated: fail on the
    // next turn instead of queueing behind the flood and waiting for the
    // refusal.
    if (shortCircuits(service, op)) {
      return _refuseOnNextTurn(shortCircuit(service));
    }
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
      bulk: bulk,
    );
    _pending[id] = call;
    _startSweeper();
    _target.send(
      CoordinatorRequest(
        id: id,
        service: service,
        op: op,
        args: args,
        replyTo: _replies.sendPort,
        deadline: args is ExpiringCoordinatorMessage
            ? DateTime.now().microsecondsSinceEpoch + timeout.inMicroseconds
            : 0,
      ),
    );
    return call.completer.future;
  }

  void _sweep() {
    final now = _clock.elapsedMicroseconds;
    var credits = 0;
    _pending.removeWhere((_, call) {
      if (now < call.deadline) {
        return false;
      }
      call.completer.completeError(
        CoordinatorTimeoutException(call.service, call.timeout),
      );
      onCallTimeout?.call(call.service);
      if (call.bulk) {
        credits++;
      }
      return true;
    });
    // Bulk calls still waiting for credit time out too.
    while (_bulkWaiting.isNotEmpty && now >= _bulkWaiting.first.deadline) {
      final waiting = _bulkWaiting.removeFirst();
      waiting.completer.completeError(
        CoordinatorTimeoutException(waiting.service, waiting.timeout),
      );
      onCallTimeout?.call(waiting.service);
    }
    // A timed-out call gives its credit back (ACK 206: not a refill on a
    // timer, which would fire exactly when the coordinator is slow).
    for (var i = 0; i < credits; i++) {
      _creditBack();
    }
    if (_pending.isEmpty && _bulkWaiting.isEmpty) {
      _sweeper?.cancel().ignore();
      _sweeper = null;
    }
  }

  void _onReply(Object? message) {
    if (message is CoordinatorHealth) {
      _onHealth(message);
      return;
    }
    if (message is CoordinatorBatchReply) {
      var credits = 0;
      for (final reply in message.replies) {
        if (_answer(reply)) {
          credits++;
        }
      }
      for (var i = 0; i < credits; i++) {
        _creditBack();
      }
      return;
    }
    if (message is CoordinatorReply && _answer(message)) {
      _creditBack();
    }
  }

  /// Completes the call [reply] answers; whether it held a bulk credit
  /// (given back by the caller). A call that timed out already is gone,
  /// and gave its credit back then.
  bool _answer(CoordinatorReply reply) {
    final call = _pending.remove(reply.id);
    if (call == null) {
      return false;
    }
    onCallDuration?.call(
      call.service,
      Duration(microseconds: _clock.elapsedMicroseconds - call.started),
    );
    final error = reply.error;
    if (error != null) {
      call.completer.completeError(
        reply.errorKind == CoordinatorErrorKind.overloaded
            ? CoordinatorOverloaded(call.service)
            : CoordinatorException(error),
      );
    } else {
      call.completer.complete(reply.result);
    }
    return call.bulk;
  }

  CoordinatorState _state = CoordinatorState.healthy;
  int _epoch = -1;
  Set<String> _shedServices = const {};

  /// The coordinator's state as it last announced it (Blueprint #141, K1).
  CoordinatorState get coordinatorState => _state;

  /// Receives each change of [coordinatorState]
  /// (`coordinator_state{state}` on `/metrics`).
  void Function(CoordinatorState state)? onStateChange;

  /// Receives the service of each call this channel failed at once,
  /// without sending it, because the coordinator is saturated
  /// (`coordinator_short_circuit_total{service}`).
  void Function(String service)? onShortCircuit;

  void _onHealth(CoordinatorHealth health) {
    // Announcements cross one port in order: only a newer one counts. The
    // coordinator lives as long as the process, so its epochs never start
    // again; a channel starts from -1.
    if (health.epoch <= _epoch) {
      return;
    }
    _epoch = health.epoch;
    _shedServices = health.shedServices.isEmpty
        ? const {}
        : health.shedServices.split(',').toSet();
    final next = CoordinatorState.values[health.state];
    if (next != _state) {
      _state = next;
      onStateChange?.call(next);
    }
    if (next == CoordinatorState.saturated && _bulkWaiting.isNotEmpty) {
      // The bulk calls waiting for credit that the coordinator now refuses
      // fail at once (counted as short-circuits), not when sent.
      final kept = ListQueue<_BufferedBulk>();
      for (final waiting in _bulkWaiting) {
        if (shortCircuits(waiting.service, waiting.op)) {
          waiting.completer.completeError(shortCircuit(waiting.service));
        } else {
          kept.add(waiting);
        }
      }
      _bulkWaiting
        ..clear()
        ..addAll(kept);
    }
  }

  /// Whether a call to [service] is failed at once: the coordinator is
  /// saturated and refuses that service's calls.
  bool shortCircuits(String service, [String op = '']) =>
      _state == CoordinatorState.saturated &&
      (_shedServices.contains(service) ||
          _shedServices.contains('$service.$op'));

  /// Records a call failed at once ([shortCircuits], or a store deciding
  /// so for a call it would otherwise wait on) and returns its error.
  CoordinatorOverloaded shortCircuit(String service) {
    onShortCircuit?.call(service);
    return CoordinatorOverloaded(service);
  }

  /// Closes the channel.
  void close() {
    _closed = true;
    _sweeper?.cancel().ignore();
    _sweeper = null;
    _replies.close();
    for (final call in _pending.values) {
      call.completer.completeError(
        const CoordinatorException('Coordinator channel closed.'),
      );
    }
    _pending.clear();
    while (_bulkWaiting.isNotEmpty) {
      _bulkWaiting.removeFirst().completer.completeError(
        const CoordinatorException('Coordinator channel closed.'),
      );
    }
    _bulkInFlight = 0;
  }
}

/// Bulk refusals of this isolate made during the current turn of its event
/// loop, failed together on the next turn ([_failOnNextTurn]).
List<(Completer<Object?>, Object, StackTrace)>? _refusalsThisTurn;

/// Fails [completer] with [error] on the next turn of the event loop, with
/// every other bulk refusal of this turn, from one timer.
///
/// A refusal (a full bulk buffer, a saturated coordinator) used to be an
/// already failed future: a caller that caught it and tried again at once
/// never let its isolate's event loop run (timers, sockets, heartbeats),
/// and 16 such senders took a 16-core machine (K1b overflow series, ACK
/// 247 §3). The completer is the caller's own, made in its zone, so the
/// error reaches it there whichever request's refusal started the timer
/// (Review #147); the timer runs in the root zone, owned by none of them.
void _failOnNextTurn(Completer<Object?> completer, Object error) {
  final trace = StackTrace.current;
  final pending = _refusalsThisTurn;
  if (pending != null) {
    pending.add((completer, error, trace));
    return;
  }
  final batch = [(completer, error, trace)];
  _refusalsThisTurn = batch;
  Zone.root.run(
    () => Timer.run(() {
      _refusalsThisTurn = null;
      for (final (refused, error, trace) in batch) {
        refused.completeError(error, trace);
      }
    }),
  );
}

/// A future of the caller's zone failing with [error] on the next turn
/// ([_failOnNextTurn]).
Future<Object?> _refuseOnNextTurn(Object error) {
  final refused = Completer<Object?>();
  _failOnNextTurn(refused, error);
  return refused.future;
}

/// An in-flight [RemoteCoordinatorChannel.call].
final class _PendingCall {
  _PendingCall(
    this.service,
    this.timeout,
    this.deadline,
    this.started, {
    this.bulk = false,
    Completer<Object?>? completer,
  }) : completer = completer ?? Completer<Object?>();

  final String service;
  final Duration timeout;

  /// Monotonic microseconds after which the call times out.
  final int deadline;

  /// Monotonic microseconds when the call was sent.
  final int started;

  /// Whether it holds one of the channel's bulk credits (K1b), given back
  /// once: by its reply, or by its timeout.
  final bool bulk;
  final Completer<Object?> completer;
}

/// A bulk call waiting in a [RemoteCoordinatorChannel]'s buffer for credit.
final class _BufferedBulk {
  _BufferedBulk(this.service, this.op, this.args, this.timeout, this.deadline);

  final String service;
  final String op;
  final Object args;
  final Duration timeout;

  /// Monotonic microseconds after which the call times out, in the buffer
  /// too.
  final int deadline;
  final Completer<Object?> completer = Completer<Object?>();
}

/// What a full bulk buffer does with one more call ([RemoteCoordinatorChannel.sendBulk]).
enum BulkOverflow {
  /// Refuses the new call ([CoordinatorOverloaded]): broadcasts, which the
  /// broadcast manager then drops and tells (`BroadcastShed`).
  refuse,

  /// Drops the oldest call waiting (its future completes with
  /// [CoordinatorOverloaded]) and keeps the new one: metrics, worker
  /// reports, records, where the latest matters most.
  dropOldest,
}

/// Bulk calls (K1b) through whatever channel: windowed by a
/// [RemoteCoordinatorChannel], a plain call through any other.
extension BulkCoordinatorCalls on CoordinatorChannel {
  /// Calls [op] on [service] as a bulk call: see
  /// [RemoteCoordinatorChannel.sendBulk].
  Future<Object?> callBulk(
    String service,
    String op,
    Map<String, Object?> args, {
    Duration timeout = const Duration(seconds: 1),
    BulkOverflow overflow = BulkOverflow.refuse,
  }) => switch (this) {
    final RemoteCoordinatorChannel remote => remote.sendBulk(
      service,
      op,
      args,
      timeout: timeout,
      overflow: overflow,
    ),
    _ => call(service, op, args, timeout: timeout),
  };
}
