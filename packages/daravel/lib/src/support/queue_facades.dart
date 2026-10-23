import 'dart:async';

import '../events/events.dart';
import '../foundation/container.dart';
import '../queue/drivers.dart';
import '../queue/job.dart';
import '../queue/queue_manager.dart';

/// Events (`Event::dispatch`, `Event::listen`, `Event::fake`).
abstract final class Event {
  static EventDispatcher get dispatcher =>
      Container.current.make<EventDispatcher>();

  static void listen<E extends Object>(
    EventListener<E> listener, {
    int priority = 0,
    bool once = false,
  }) => dispatcher.listen<E>(listener, priority: priority, once: once);

  static void subscribe(EventSubscriber subscriber) =>
      dispatcher.subscribe(subscriber);

  static Future<void> dispatch<E extends Object>(E event) =>
      dispatcher.dispatch<E>(event);

  static Future<void> dispatchAfterCommit<E extends Object>(E event) =>
      dispatcher.dispatchAfterCommit<E>(event);

  static Stream<E> on<E extends Object>() => dispatcher.on<E>();

  static bool hasListeners<E extends Object>() => dispatcher.hasListeners<E>();

  static void forget<E extends Object>() => dispatcher.forget<E>();

  static EventFake fake() => dispatcher.fake();

  static void restore() => dispatcher.restore();
}

/// Queue (`Queue::push`, `dispatch()`, `Queue::fake`).
abstract final class Queue {
  static QueueManager get manager => Container.current.make<QueueManager>();

  static QueueDriver connection([String? name]) => manager.connection(name);

  /// Fluent dispatch: `await Queue.dispatch(job).onQueue('emails')`.
  static PendingDispatch dispatch(Job job) => manager.dispatch(job);

  static Future<Object?> push(
    Job job, {
    String? queue,
    String? connection,
    Duration? delay,
  }) => manager.push(job, queue: queue, connection: connection, delay: delay);

  static Future<Object?> later(
    Duration delay,
    Job job, {
    String? queue,
    String? connection,
  }) => manager.later(delay, job, queue: queue, connection: connection);

  static Future<List<Object?>> bulk(
    Iterable<Job> jobs, {
    String? queue,
    String? connection,
  }) => manager.bulk(jobs, queue: queue, connection: connection);

  static Future<int> size([String? queue, String? connection]) =>
      manager.connection(connection).size(queue ?? manager.config.defaultQueue);

  static QueueFake fake() => manager.fake();

  static void restore() => manager.restore();
}
