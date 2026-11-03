import 'dart:async';

import '../events/events.dart';
import '../foundation/container.dart';
import '../queue/drivers.dart';
import '../queue/job.dart';
import '../queue/queue_manager.dart';

/// Events (`Event::dispatch`, `Event::listen`, `Event::fake`).
abstract final class Event {
  /// The event dispatcher of the current container.
  static EventDispatcher get dispatcher =>
      Container.current.make<EventDispatcher>();

  /// Calls the listener for every event of type [E].
  static void listen<E extends Object>(
    EventListener<E> listener, {
    int priority = 0,
    bool once = false,
  }) => dispatcher.listen<E>(listener, priority: priority, once: once);

  /// Registers the listeners [subscriber] declares.
  static void subscribe(EventSubscriber subscriber) =>
      dispatcher.subscribe(subscriber);

  /// Calls the listeners of [event] now; queued listeners are queued.
  static Future<void> dispatch<E extends Object>(E event) =>
      dispatcher.dispatch<E>(event);

  /// Dispatches [event] after the current transaction commits, or now
  /// outside one.
  static Future<void> dispatchAfterCommit<E extends Object>(E event) =>
      dispatcher.dispatchAfterCommit<E>(event);

  /// The events of type [E], as a stream.
  static Stream<E> on<E extends Object>() => dispatcher.on<E>();

  /// Whether [E] has listeners.
  static bool hasListeners<E extends Object>() => dispatcher.hasListeners<E>();

  /// Removes the listeners of [E].
  static void forget<E extends Object>() => dispatcher.forget<E>();

  /// Records events instead of dispatching them, for tests.
  static EventFake fake() => dispatcher.fake();

  /// Undoes [fake].
  static void restore() => dispatcher.restore();
}

/// Queue (`Queue::push`, `dispatch()`, `Queue::fake`).
abstract final class Queue {
  /// The queue manager of the current container.
  static QueueManager get manager => Container.current.make<QueueManager>();

  /// The queue connection [name], or the default one.
  static QueueDriver connection([String? name]) => manager.connection(name);

  /// Sends jobs of type [T] to [queue] or [connection]; see
  /// [QueueManager.route].
  static void route<T extends Job>({String? queue, String? connection}) =>
      manager.route<T>(queue: queue, connection: connection);

  /// Fluent dispatch: `await Queue.dispatch(job).onQueue('emails')`.
  static PendingDispatch dispatch(Job job) => manager.dispatch(job);

  /// Pushes a job onto the queue.
  static Future<Object?> push(
    Job job, {
    String? queue,
    String? connection,
    Duration? delay,
  }) => manager.push(job, queue: queue, connection: connection, delay: delay);

  /// Pushes a job to run after a delay.
  static Future<Object?> later(
    Duration delay,
    Job job, {
    String? queue,
    String? connection,
  }) => manager.later(delay, job, queue: queue, connection: connection);

  /// Pushes several jobs at once.
  static Future<List<Object?>> bulk(
    Iterable<Job> jobs, {
    String? queue,
    String? connection,
  }) => manager.bulk(jobs, queue: queue, connection: connection);

  /// The number of jobs waiting on [queue].
  static Future<int> size([String? queue, String? connection]) =>
      manager.connection(connection).size(queue ?? manager.config.defaultQueue);

  /// Records pushed jobs instead of queueing them, for tests.
  static QueueFake fake() => manager.fake();

  /// Undoes [fake].
  static void restore() => manager.restore();
}
