import 'dart:io';

import '../broadcasting/broadcast_manager.dart';
import '../foundation/container.dart';
import '../server/broadcast.dart';

/// Broadcasting, at two levels:
///
/// - [event] and [send] broadcast events to Laravel Echo clients, through
///   `BROADCAST_CONNECTION` (this server's Pusher protocol, or a Reverb or
///   Pusher Channels elsewhere), as Laravel's `broadcast()` helper does;
/// - [publish], [subscribe] and [pipe] are Daravel's own channels between
///   worker isolates, for your own WebSocket or SSE routes.
///
/// ```dart
/// await Broadcast.event(OrderShipped(order).toOthers());
/// await Broadcast.send('price.updated', ['prices'], {'sku': 'A1', 'price': 12});
///
/// await Broadcast.publish('orders.7', {'status': 'shipped'});
/// r.ws('/ws/orders/{id}', (socket, request) =>
///     Broadcast.pipe(socket, ['orders.${request.param<int>('id')}']));
/// ```
abstract final class Broadcast {
  static Broadcaster get broadcaster => Container.current.make<Broadcaster>();

  static BroadcastManager get manager =>
      Container.current.make<BroadcastManager>();

  /// Broadcasts a [ShouldBroadcast] event, as Laravel's `broadcast()`
  /// helper; `Event.dispatch` does the same for such events.
  static Future<void> event(ShouldBroadcast event) => manager.broadcast(event);

  /// Broadcasts [event] with [data] to [channels] (`private-…`,
  /// `presence-…` or public), leaving out [exceptSocket].
  static Future<void> send(
    String event,
    List<String> channels,
    Object? data, {
    String? exceptSocket,
  }) => manager.send(event, channels, data, exceptSocket: exceptSocket);

  /// Sends [message] (a `String`, or anything as JSON) to [channel];
  /// returns how many isolates received it.
  static Future<int> publish(String channel, Object? message) =>
      broadcaster.publish(channel, message);

  /// Listens to [channel] until the subscription is cancelled.
  static Future<BroadcastSubscription> subscribe(String channel) =>
      broadcaster.subscribe(channel);

  /// Forwards [channels] to [socket] until it closes.
  static Future<void> pipe(
    WebSocket socket,
    List<String> channels, {
    void Function(Object? message)? onMessage,
  }) => broadcaster.pipe(socket, channels, onMessage: onMessage);
}
