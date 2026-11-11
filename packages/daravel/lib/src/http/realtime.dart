import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../foundation/container.dart';
import '../foundation/drain.dart';
import 'request.dart';
import 'response.dart';

/// One server-sent event (Laravel's `StreamedEvent`): [event] defaults to
/// `update` as in Laravel's `response()->eventStream()`; [data] that is not
/// a string or number is sent as JSON.
final class SseEvent {
  /// An event carrying [data], named [event] (`update`), with an optional
  /// [id] and reconnection delay.
  const SseEvent(this.data, {this.event = 'update', this.id, this.retry})
    : comment = null;

  /// A comment line (`: text`), which clients ignore (a heartbeat).
  const SseEvent.comment(String text)
    : comment = text,
      data = null,
      event = null,
      id = null,
      retry = null;

  /// The event data: a string or number as written, anything else as JSON.
  final Object? data;

  /// The event name (`event:`), `update` by default.
  final String? event;

  /// Sent as `id:`; the browser returns it as `Last-Event-ID` when it
  /// reconnects (`request.header('last-event-id')`).
  final String? id;

  /// Asks the client to wait this long before reconnecting.
  final Duration? retry;

  /// The text of a comment frame, or null for an event.
  final String? comment;

  /// The frame on the wire. A multi-line value becomes one `data:` line per
  /// line (the EventSource format; Laravel writes them on one line).
  String encode() {
    final lines = StringBuffer();
    final text = comment;
    if (text != null) {
      for (final line in const LineSplitter().convert(text)) {
        lines.write(': $line\n');
      }
      return '${lines.isEmpty ? ':\n' : lines}\n';
    }
    if (event case final String name) {
      lines.write('event: $name\n');
    }
    if (id case final String value) {
      lines.write('id: ${value.replaceAll(RegExp('[\r\n]'), '')}\n');
    }
    if (retry case final Duration wait) {
      lines.write('retry: ${wait.inMilliseconds}\n');
    }
    final payload = switch (data) {
      final String text => text,
      final num number => '$number',
      final other => Response.encodeJson(other),
    };
    for (final line in payload.split(RegExp(r'\r\n|\r|\n'))) {
      lines.write('data: $line\n');
    }
    return '$lines\n';
  }
}

/// Counts realtime clients the server disconnected for reading too slowly
/// (`realtime_slow_clients_total`, by transport): WebSockets with more than
/// their route's `maxBufferedBytes` waiting to be sent, and server-sent
/// event streams with more than `Response.sse`'s.
final class SlowClients {
  /// A counter that also tells [onSlowClient] (the application's metrics).
  SlowClients({this.onSlowClient});

  /// The transport of a WebSocket.
  static const String webSocket = 'websocket';

  /// The transport of a server-sent event stream.
  static const String sse = 'sse';

  /// Called with the transport of each slow client.
  final void Function(String transport)? onSlowClient;

  final Map<String, int> _counts = <String, int>{};

  /// Slow clients of [transport] disconnected so far by this isolate.
  int count(String transport) => _counts[transport] ?? 0;

  /// Counts one slow client of [transport].
  void record(String transport) {
    _counts[transport] = count(transport) + 1;
    onSlowClient?.call(transport);
  }
}

/// The body of `Response.sse`: [events] (each an [SseEvent] or a value sent
/// as an `update` event), a heartbeat comment every [heartbeat] while idle,
/// then [endStreamWith] (Laravel's `</stream>`, `null` for none). Ends early
/// when the application starts draining; cancelling (the client went away)
/// cancels [events].
///
/// [events] is read as fast as it produces; what the client has not taken
/// yet is counted, and past [maxBufferedBytes] the stream ends with a
/// `retry:` line instead of `endStreamWith`, so `EventSource` reconnects,
/// and [events] is cancelled. A paused source would queue its events in
/// memory instead, unbounded and unseen. With [maxBufferedBytes] null the
/// source is paused while the client is behind (a generator that honours
/// pause, with nothing queued behind it).
Stream<List<int>> sseStream(
  Stream<Object?> events, {
  Object? endStreamWith = '</stream>',
  Duration? heartbeat = const Duration(seconds: 15),
  int? maxBufferedBytes = Response.defaultSseMaxBufferedBytes,
}) {
  late final StreamController<List<int>> controller;
  StreamSubscription<Object?>? subscription;
  Timer? timer;
  var closed = false;
  // Bytes handed to the controller that the response has not taken yet.
  var queued = 0;
  void Function()? stopDraining;

  void stopListening() {
    closed = true;
    timer?.cancel();
    stopDraining?.call();
    stopDraining = null;
  }

  void write(String frame) {
    final bytes = utf8.encode(frame);
    queued += bytes.length;
    controller.add(bytes);
  }

  void slowClient() {
    stopListening();
    // After what is queued: EventSource comes back in a second.
    write('retry: ${_slowClientRetry.inMilliseconds}\n\n');
    final source = subscription;
    subscription = null;
    unawaited(source?.cancel());
    unawaited(controller.close());
    try {
      Container.current.tryMake<SlowClients>()?.record(SlowClients.sse);
    } on StateError {
      // No container: nothing counts slow clients.
    }
  }

  void send(SseEvent event) {
    if (closed) {
      return;
    }
    write(event.encode());
    final limit = maxBufferedBytes;
    if (limit != null && queued > limit) {
      slowClient();
    }
  }

  Future<void> finish() async {
    if (closed) {
      return;
    }
    if (endStreamWith != null) {
      send(endStreamWith is SseEvent ? endStreamWith : SseEvent(endStreamWith));
      if (closed) {
        return; // that last event made it a slow client
      }
    }
    stopListening();
    await subscription?.cancel();
    await controller.close();
  }

  void beat() {
    timer?.cancel();
    final every = heartbeat;
    if (every != null && !closed) {
      timer = Timer(every, () {
        send(const SseEvent.comment('keep-alive'));
        beat();
      });
    }
  }

  DrainSignal? drain;
  try {
    drain = Container.current.tryMake<DrainSignal>();
  } on StateError {
    drain = null;
  }

  controller = StreamController<List<int>>(
    onListen: () {
      // dart:io sends the headers with the first bytes: an empty comment
      // opens the stream at once (EventSource fires `open`).
      send(const SseEvent.comment(''));
      subscription = events.listen(
        (item) {
          send(item is SseEvent ? item : SseEvent(item));
          beat();
        },
        onError: (Object error, StackTrace stackTrace) =>
            controller.addError(error, stackTrace),
        onDone: finish,
      );
      beat();
      // Removed when the stream ends: a listener on DrainSignal.future
      // would hold this stream until shutdown.
      stopDraining = drain?.onDrain(() {
        // A reconnect delay of 1 to 5 s, random, before the end: the
        // clients of a server shutting down do not all come back at once.
        if (!closed) {
          write('retry: ${1000 + _drainRandom.nextInt(4001)}\n\n');
        }
        unawaited(finish());
      });
    },
    onPause: maxBufferedBytes == null ? () => subscription?.pause() : null,
    onResume: maxBufferedBytes == null ? () => subscription?.resume() : null,
    onCancel: () async {
      // The client disconnected.
      stopListening();
      await subscription?.cancel();
    },
  );
  return controller.stream.map((chunk) {
    // The response took it: no longer waiting.
    queued -= chunk.length;
    return chunk;
  });
}

/// How long `EventSource` waits before reconnecting after the server ended
/// its stream for reading too slowly.
const Duration _slowClientRetry = Duration(seconds: 1);

final Random _drainRandom = Random();

/// Handles an upgraded connection (`router.ws`).
typedef WebSocketHandler = FutureOr<void> Function(
  WebSocket socket,
  Request request,
);

/// Whether [request] asks to switch to the WebSocket protocol.
bool isWebSocketUpgrade(Request request) =>
    (request.header('upgrade') ?? '').toLowerCase() == 'websocket' &&
    (request.header('connection') ?? '').toLowerCase().contains('upgrade');
