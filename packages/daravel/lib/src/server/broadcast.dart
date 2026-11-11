import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import '../foundation/detached.dart';
import '../foundation/shared_result.dart';
import 'coordinator.dart';

/// Coordinator side of [Broadcaster]: which isolates listen to which
/// channel, and the fan-out of each message to them.
///
/// An isolate registers its port for a channel when its first local
/// listener subscribes and removes it when the last one leaves, so a
/// message only crosses to isolates that have someone listening.
final class BroadcastService
    with PrioritizedService
    implements CoordinatorService, WorkerAwareService {
  /// Bulk: fan-out waits while the coordinator lags, and is refused while
  /// it is saturated, so rate limits and locks keep their answers.
  @override
  CoordinatorPriority get priority => CoordinatorPriority.bulk;

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
  /// A broadcaster publishing through the coordinator.
  Broadcaster(this._coordinator);

  final CoordinatorChannel _coordinator;
  final Map<String, Set<StreamController<String>>> _local =
      <String, Set<StreamController<String>>>{};
  // Shared by the subscribers of a channel in this isolate, from different
  // connections: a SharedResult, so a failed registration reaches each of
  // them (as a failing future it would hang those of another zone).
  final Map<String, SharedResult<void>> _registering =
      <String, SharedResult<void>>{};
  final Map<String, Future<void>> _leaving = <String, Future<void>>{};
  final Set<String> _straying = <String>{};
  ReceivePort? _port;

  SendPort get _sendPort {
    final existing = _port;
    if (existing != null) {
      return existing.sendPort;
    }
    // Detached: one port for the isolate, opened by its first subscriber,
    // whose request's zone would otherwise handle every frame for the life
    // of the process (Review #149).
    final port = runDetached(
      () => ReceivePort('daravel-broadcast')
        ..listen((Object? message) {
          if (message case [final String channel, final String text]) {
            final listeners = _local[channel];
            if (listeners == null) {
              _stray(channel);
              return;
            }
            for (final listener in [...listeners]) {
              listener.add(text);
            }
          }
        }),
      name: 'broadcast receiver',
      stop: (port) => port.close(),
    ).value;
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
  ///
  /// When the coordinator cannot register this isolate (a timeout, a full
  /// queue), this throws and leaves nothing behind: the next subscriber
  /// tries again.
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
    final registration = _registering[channel] ??= SharedResult<void>(
      () => _register(channel),
    );
    try {
      await registration.value;
    } on Object {
      // Undone here, or every later subscriber of this isolate would wait
      // on the same failed registration for ever.
      if (identical(_registering[channel], registration)) {
        _registering.remove(channel);
      }
      final current = _local[channel];
      if (current != null && current.remove(controller) && current.isEmpty) {
        _local.remove(channel);
      }
      unawaited(controller.close());
      rethrow;
    }
    return BroadcastSubscription._(
      channel,
      controller,
      () => _leave(channel, controller),
    );
  }

  /// Registers this isolate's port for [channel], after an unsubscribe of
  /// the same channel still on its way (the coordinator must not get the
  /// subscribe first).
  Future<void> _register(String channel) async {
    final leaving = _leaving[channel];
    if (leaving != null) {
      await leaving;
    }
    await _coordinator.call('broadcast', 'subscribe', {
      'channel': channel,
      'port': _sendPort,
      'worker': Isolate.current.debugName,
    });
  }

  /// Forwards the messages of [channels] to [socket] until it closes, then
  /// unsubscribes. Messages the client sends are ignored unless
  /// [onMessage] handles them, one at a time: an asynchronous handler is
  /// awaited before the next message is read, so a client cannot queue
  /// work faster than it is done.
  Future<void> pipe(
    WebSocket socket,
    List<String> channels, {
    FutureOr<void> Function(Object? message)? onMessage,
  }) async {
    final subscriptions = [
      for (final channel in channels) await subscribe(channel),
    ];
    for (final subscription in subscriptions) {
      subscription.messages.listen((message) {
        // A message can arrive between the close and the unsubscribe below.
        if (socket.closeCode == null) {
          try {
            socket.add(message);
          } on StateError {
            // Closed by this side, the close not answered yet.
          }
        }
      });
    }
    try {
      await for (final Object? message in socket) {
        try {
          await onMessage?.call(message);
        } catch (error, stackTrace) {
          // As a listener's error was: reported, and the next message read.
          Zone.current.handleUncaughtError(error, stackTrace);
        }
      }
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
      final registration = _registering.remove(channel);
      final leaving = _unregister(channel, registration);
      _leaving[channel] = leaving;
      try {
        await leaving;
      } finally {
        if (identical(_leaving[channel], leaving)) {
          unawaited(_leaving.remove(channel));
        }
      }
    }
  }

  /// Unsubscribes this isolate's port from [channel] once [registration]
  /// has landed. A failure is not the caller's: the port stays registered,
  /// and the next message for the channel unsubscribes it again (see
  /// [_stray]).
  Future<void> _unregister(
    String channel,
    SharedResult<void>? registration,
  ) async {
    // Let the registration finish first, so it cannot land after this.
    try {
      await registration?.value;
    } on Object {
      // It failed: the subscriber has the error. It may still land late;
      // a message that then arrives unsubscribes again.
      return;
    }
    // After close() the port is gone and the coordinator is going with
    // the application: asking for _sendPort would open a new port that
    // nothing closes, and the isolate could never exit.
    final port = _port;
    if (port == null) {
      return;
    }
    try {
      await _coordinator.call('broadcast', 'unsubscribe', {
        'channel': channel,
        'port': port.sendPort,
      });
    } on Object {
      // Left registered: messages for it are dropped here, and the first
      // one unsubscribes again.
    }
  }

  /// A message for [channel] reached this isolate with nobody listening:
  /// an unsubscribe failed, or a subscribe that timed out landed after
  /// all. Unsubscribe again, once at a time.
  void _stray(String channel) {
    final port = _port;
    if (port == null ||
        _registering.containsKey(channel) ||
        _leaving.containsKey(channel) ||
        !_straying.add(channel)) {
      return;
    }
    unawaited(
      _coordinator
          .call('broadcast', 'unsubscribe', {
            'channel': channel,
            'port': port.sendPort,
          })
          .then<void>((_) {}, onError: (Object _) {})
          .whenComplete(() => _straying.remove(channel)),
    );
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

  /// The channel of the message.
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
