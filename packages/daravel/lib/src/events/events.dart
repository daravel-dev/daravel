import 'dart:async';

import '../foundation/exceptions.dart';
import '../queue/job.dart';

export 'framework_events.dart';

/// Handles an event of type `E`.
typedef EventListener<E extends Object> = FutureOr<void> Function(E event);

/// Groups listeners (Laravel `EventSubscriber`).
abstract interface class EventSubscriber {
  void subscribe(EventDispatcher events);
}

/// A listener executed on the queue (`ShouldQueue`). The event must be
/// JSON-serializable through [eventToJson]/[eventFromJson].
abstract class QueuedListener<E extends Object> {
  const QueuedListener();

  /// Stable registry name (defaults to the class name).
  String get listenerName => runtimeType.toString();

  Future<void> handle(E event);

  Map<String, Object?> eventToJson(E event);

  E eventFromJson(Map<String, Object?> json);

  int get tries => 1;

  String? get queue => null;
}

/// Job wrapping a [QueuedListener] invocation.
final class CallQueuedListener extends Job {
  const CallQueuedListener(this._dispatcher, this.listenerName, this.event);

  static const String jobPrefix = 'daravel:listener:';

  final EventDispatcher _dispatcher;
  final String listenerName;
  final Map<String, Object?> event;

  @override
  String get jobName => '$jobPrefix$listenerName';

  @override
  String get displayName => listenerName;

  @override
  int get tries => _dispatcher._queued[listenerName]?.listener.tries ?? 1;

  @override
  String? get queue => _dispatcher._queued[listenerName]?.listener.queue;

  @override
  Map<String, Object?> toJson() => <String, Object?>{'event': event};

  @override
  Future<void> handle(JobContext ctx) =>
      _dispatcher.invokeQueued(listenerName, event);
}

final class _Listener {
  _Listener(this.type, this.matches, this.invoke, this.priority, this.once);

  final Type type;
  final bool Function(Object event) matches;
  final Future<void> Function(Object event) invoke;
  final int priority;
  final bool once;
}

final class _QueuedEntry {
  _QueuedEntry(
    this.type,
    this.listener,
    this.matches,
    this.invokeJson,
    this.toJson,
  );

  final Type type;
  final QueuedListener<Object> listener;
  final bool Function(Object event) matches;
  final Future<void> Function(Map<String, Object?> json) invokeJson;
  final Map<String, Object?> Function(Object event) toJson;
}

/// Recorded dispatches while [EventDispatcher.fake] is active.
final class EventFake {
  final List<Object> dispatched = <Object>[];

  /// Events of type `E` (optionally filtered).
  List<E> of<E extends Object>([bool Function(E event)? where]) => [
    for (final e in dispatched)
      if (e is E && (where == null || where(e))) e,
  ];

  bool wasDispatched<E extends Object>([bool Function(E event)? where]) =>
      of<E>(where).isNotEmpty;

  int dispatchedTimes<E extends Object>() => of<E>().length;

  void assertDispatched<E extends Object>([bool Function(E event)? where]) {
    if (!wasDispatched<E>(where)) {
      throw StateError('Expected event [$E] to be dispatched; it was not.');
    }
  }

  void assertNotDispatched<E extends Object>() {
    if (wasDispatched<E>()) {
      throw StateError('Expected event [$E] not to be dispatched; it was.');
    }
  }

  void assertNothingDispatched() {
    if (dispatched.isNotEmpty) {
      throw StateError(
        'Expected no events; got '
        '${dispatched.map((e) => e.runtimeType).join(', ')}.',
      );
    }
  }
}

/// Defers work until the active transaction commits
/// (`DatabaseManager.afterCommit`).
typedef AfterCommitHook = Future<void> Function(FutureOr<void> Function());

/// Pushes a job onto the queue (`QueueManager.push`).
typedef QueuePusher = Future<Object?> Function(Job job);

/// Synchronous + queued event dispatching (BLUEPRINT_V2 §7.8).
final class EventDispatcher {
  EventDispatcher();

  final List<_Listener> _listeners = <_Listener>[];
  final Map<String, _QueuedEntry> _queued = <String, _QueuedEntry>{};
  final Map<Type, StreamController<Object>> _streams = {};
  EventFake? _fake;

  /// Defers until commit when inside a transaction (set by the application).
  AfterCommitHook? afterCommitHook;

  /// Pushes jobs for queued listeners (set by the application).
  QueuePusher? queuePusher;

  /// Registers [listener] for events of type `E` (and subtypes). Higher
  /// [priority] runs first; [once] removes the listener after its first call.
  void listen<E extends Object>(
    EventListener<E> listener, {
    int priority = 0,
    bool once = false,
  }) {
    _listeners.add(
      _Listener(
        E,
        (event) => event is E,
        (event) async => listener(event as E),
        priority,
        once,
      ),
    );
    _listeners.sort((a, b) => b.priority.compareTo(a.priority));
  }

  /// Registers a queued listener; dispatching `E` pushes a job instead of
  /// running the listener inline. Returns the job definition that must be
  /// in the job registry so workers can rebuild it.
  JobDefinition listenQueued<E extends Object>(QueuedListener<E> listener) {
    final name = listener.listenerName;
    if (_queued.containsKey(name)) {
      throw ConfigException('Queued listener [$name] is registered twice.');
    }
    _queued[name] = _QueuedEntry(
      E,
      listener,
      (event) => event is E,
      (json) => listener.handle(listener.eventFromJson(json)),
      (event) => listener.eventToJson(event as E),
    );
    return JobDefinition(
      '${CallQueuedListener.jobPrefix}$name',
      (json) => CallQueuedListener(
        this,
        name,
        (json['event'] as Map<String, Object?>?) ?? const {},
      ),
    );
  }

  void subscribe(EventSubscriber subscriber) => subscriber.subscribe(this);

  bool hasListeners<E extends Object>() =>
      _listeners.any((l) => l.type == E) ||
      _queued.values.any((q) => q.type == E) ||
      _streams[E]?.hasListener == true;

  /// Removes every inline and queued listener registered for exactly `E`.
  void forget<E extends Object>() {
    _listeners.removeWhere((l) => l.type == E);
    _queued.removeWhere((_, q) => q.type == E);
    _streams.remove(E)?.close();
  }

  /// A broadcast stream of events of type `E`.
  Stream<E> on<E extends Object>() =>
      (_streams[E] ??= StreamController<Object>.broadcast()).stream.cast<E>();

  /// Dispatches [event]: inline listeners by priority (awaited), then queued
  /// listeners as jobs, then streams.
  Future<void> dispatch<E extends Object>(E event) async {
    final fake = _fake;
    if (fake != null) {
      fake.dispatched.add(event);
      return;
    }
    final matched = _listeners.where((l) => l.matches(event)).toList();
    for (final listener in matched) {
      if (listener.once) {
        _listeners.remove(listener);
      }
      await listener.invoke(event);
    }
    for (final entry in _queued.entries) {
      if (!entry.value.matches(event)) {
        continue;
      }
      final pusher = queuePusher;
      if (pusher == null) {
        throw StateError(
          'Queued listener [${entry.key}] needs a queue; none is attached.',
        );
      }
      await pusher(
        CallQueuedListener(this, entry.key, entry.value.toJson(event)),
      );
    }
    for (final entry in _streams.entries) {
      if (entry.value.hasListener && event.runtimeType == entry.key) {
        entry.value.add(event);
      }
    }
    await broadcastHook?.call(event);
  }

  /// Dispatches after the active transaction commits, or immediately when
  /// no transaction is active (`ShouldDispatchAfterCommit`).
  /// Called with every dispatched event after its listeners; the
  /// application broadcasts the ones that are `ShouldBroadcast`.
  Future<void> Function(Object event)? broadcastHook;

  Future<void> dispatchAfterCommit<E extends Object>(E event) {
    final hook = afterCommitHook;
    if (hook == null) {
      return dispatch(event);
    }
    return hook(() => dispatch(event));
  }

  /// Records dispatches instead of running listeners (tests).
  EventFake fake() => _fake = EventFake();

  /// Stops faking.
  void restore() => _fake = null;

  /// Invokes a queued listener by name with its JSON event (worker side).
  Future<void> invokeQueued(String name, Map<String, Object?> json) {
    final entry = _queued[name];
    if (entry == null) {
      throw StateError('Queued listener [$name] is not registered.');
    }
    return entry.invokeJson(json);
  }
}
