import 'dart:io';

import '../foundation/container.dart';
import '../server/broadcast.dart';

/// Messages to channels that reach every worker isolate of the server:
///
/// ```dart
/// await Broadcast.publish('orders.7', {'status': 'shipped'});
///
/// r.ws('/ws/orders/{id}', (socket, request) =>
///     Broadcast.pipe(socket, ['orders.${request.param<int>('id')}']));
/// ```
abstract final class Broadcast {
  static Broadcaster get broadcaster => Container.current.make<Broadcaster>();

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
