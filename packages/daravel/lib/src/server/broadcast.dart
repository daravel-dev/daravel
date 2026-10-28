import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'coordinator.dart';

/// Coordinator side of [Broadcaster]: which isolates listen to which
/// channel, and the fan-out of each message to them.
///
/// An isolate registers its port for a channel when its first local
/// listener subscribes and removes it when the last one leaves, so a
/// message only crosses to isolates that have someone listening.
final class BroadcastService implements CoordinatorService, WorkerAwareService {
  final Map<String, Set<SendPort>> _channels = <String, Set<SendPort>>{};

  /// The ports each worker registered (`subscribe`'s `worker`), so a
  /// crashed worker's ports are dropped: sends to them went nowhere, and a
  /// respawn registered new ones, so the sets only grew.
  final Map<String, Set<SendPort>> _byWorker = <String, Set<SendPort>>{};
  int _published = 0;
  int _delivered = 0;

  @override
  String get name => 'broadcast';

  @override
  void forgetWorker(String worker) {
    final ports = _byWorker.remove(worker);
    if (ports == null) {
      return;
    }
    for (final channel in _channels.keys.toList()) {
      final subscribers = _channels[channel]!..removeAll(ports);
      if (subscribers.isEmpty) {
        _channels.remove(channel);
      }
    }
  }

  @override
  Object? handle(String op, Map<String, Object?> args) {
    final channel = args['channel']! as String;
    switch (op) {
      case 'subscribe':
        final port = args['port']! as SendPort;
        _channels.putIfAbsent(channel, () => <SendPort>{}).add(port);
        if (args['worker'] case final String worker) {
          _byWorker.putIfAbsent(worker, () => <SendPort>{}).add(port);
        }
        return null;
      case 'unsubscribe':
        final ports = _channels[channel];
        ports?.remove(args['port']! as SendPort);
        if (ports != null && ports.isEmpty) {
          _channels.remove(channel);
        }
        return null;
      case 'publish':
        _published++;
        final ports = _channels[channel];
        if (ports == null) {
          return 0;
        }
        final message = [channel, args['message']! as String];
        for (final port in ports) {
          port.send(message);
        }
        _delivered += ports.length;
        return ports.length;
    }
    throw CoordinatorException('Unknown broadcast operation [$op].');
  }

  @override
  Map<String, Object?> stats() => <String, Object?>{
    'channels': _channels.length,
    'published': _published,
    'delivered': _delivered,
  };
}

/// Publishes messages to channels that listeners in every worker isolate
/// receive, for example a chat room or an order's status page served over
/// WebSockets or server-sent events.
///
/// ```dart
/// // Any isolate: a controller, a job, a listener.
/// await Broadcast.publish('orders.7', {'status': 'shipped'});
///
/// // The isolate that holds the connection.
/// r.ws('/ws/orders/{id}', (socket, request) =>
///     Broadcast.pipe(socket, ['orders.${request.param<int>('id')}']));
/// ```
///
/// Messages go through the coordinator, so they reach every isolate of
/// this server, not other servers: for several machines, publish through a
/// shared system (a database, a queue) instead. Delivery is at most once,
/// in publish order per publisher, and starts when [subscribe] completes.
final class Broadcaster {
  Broadcaster(this._coordinator);

  final CoordinatorChannel _coordinator;
  final Map<String, Set<StreamController<String>>> _local =
      <String, Set<StreamController<String>>>{};
  final Map<String, Future<void>> _registering = <String, Future<void>>{};
  ReceivePort? _port;

  SendPort get _sendPort {
    final existing = _port;
    if (existing != null) {
      return existing.sendPort;
    }
    final port = ReceivePort('daravel-broadcast');
    port.listen((Object? message) {
      if (message case [final String channel, final String text]) {
        for (final listener in [...?_local[channel]]) {
          listener.add(text);
        }
      }
    });
    _port = port;
    return port.sendPort;
  }

  /// Sends [message] to everyone subscribed to [channel]: a `String` as it
  /// is, anything else as JSON. Returns how many isolates received it.
  Future<int> publish(String channel, Object? message) async {
    final text = message is String ? message : jsonEncode(message);
    final receivers = await _coordinator.call('broadcast', 'publish', {
      'channel': channel,
      'message': text,
    });
    return receivers! as int;
  }

  /// Hands [text] to this isolate's listeners of [channel] only: for
  /// messages that reached every isolate some other way (the Pusher
  /// server's relay between machines, which each isolate reads itself).
  void deliverLocally(String channel, String text) {
    for (final listener in [...?_local[channel]]) {
      listener.add(text);
    }
  }

  /// Listens to [channel]. The returned subscription receives every
  /// message published after this completes; cancel it when done.
  Future<BroadcastSubscription> subscribe(String channel) async {
    late final StreamController<String> controller;
    controller = StreamController<String>(
      onCancel: () => _leave(channel, controller),
    );
    final listeners = _local.putIfAbsent(
      channel,
      () => <StreamController<String>>{},
    );
    listeners.add(controller);
    if (listeners.length == 1) {
      _registering[channel] = _coordinator.call('broadcast', 'subscribe', {
        'channel': channel,
        'port': _sendPort,
        'worker': Isolate.current.debugName,
      });
    }
    await _registering[channel];
    return BroadcastSubscription._(
      channel,
      controller,
      () => _leave(channel, controller),
    );
  }

  /// Forwards the messages of [channels] to [socket] until it closes, then
  /// unsubscribes. Messages the client sends are ignored unless
  /// [onMessage] handles them.
  Future<void> pipe(
    WebSocket socket,
    List<String> channels, {
    void Function(Object? message)? onMessage,
  }) async {
    final subscriptions = [
      for (final channel in channels) await subscribe(channel),
    ];
    for (final subscription in subscriptions) {
      subscription.messages.listen((message) {
        // A message can arrive between the close and the unsubscribe below.
        if (socket.closeCode == null) {
          socket.add(message);
        }
      });
    }
    try {
      await socket.listen(onMessage ?? (_) {}).asFuture<void>();
    } on Object {
      // The connection dropped; the subscriptions end below either way.
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    }
  }

  Future<void> _leave(
    String channel,
    StreamController<String> controller,
  ) async {
    final listeners = _local[channel];
    if (listeners == null || !listeners.remove(controller)) {
      return;
    }
    if (listeners.isEmpty) {
      _local.remove(channel);
      // Let the registration finish first, so it cannot land after this.
      try {
        await _registering.remove(channel);
      } on Object {
        // It failed: the subscriber has the error; there is nothing to undo.
      }
      // After close() the port is gone and the coordinator is going with
      // the application: asking for _sendPort would open a new port that
      // nothing closes, and the isolate could never exit.
      final port = _port;
      if (port == null) {
        return;
      }
      await _coordinator.call('broadcast', 'unsubscribe', {
        'channel': channel,
        'port': port.sendPort,
      });
    }
  }

  /// Closes every subscription of this isolate (application shutdown).
  Future<void> close() async {
    for (final listeners in [..._local.values]) {
      for (final controller in [...listeners]) {
        // Not awaited: close() of a stream nobody listened to never completes.
        unawaited(controller.close());
      }
    }
    _port?.close();
    _port = null;
  }
}

/// A listener on one channel of a [Broadcaster].
final class BroadcastSubscription {
  BroadcastSubscription._(this.channel, this._controller, this._leave);

  final String channel;
  final StreamController<String> _controller;
  final Future<void> Function() _leave;

  /// The messages, as published (JSON for anything but a string).
  Stream<String> get messages => _controller.stream;

  /// Stops listening; the isolate leaves the channel with its last listener.
  Future<void> cancel() async {
    await _leave();
    // Not awaited: close() of a stream nobody listened to never completes.
    unawaited(_controller.close());
  }
}
