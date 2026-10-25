import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../foundation/container.dart';
import '../foundation/drain.dart';
import 'request.dart';
import 'response.dart';

/// One server-sent event (Laravel's `StreamedEvent`): [event] defaults to
/// `update` as in Laravel's `response()->eventStream()`; [data] that is not
/// a string or number is sent as JSON.
final class SseEvent {
  const SseEvent(this.data, {this.event = 'update', this.id, this.retry})
    : comment = null;

  /// A comment line (`: text`), which clients ignore (a heartbeat).
  const SseEvent.comment(String text)
    : comment = text,
      data = null,
      event = null,
      id = null,
      retry = null;

  final Object? data;
  final String? event;

  /// Sent as `id:`; the browser returns it as `Last-Event-ID` when it
  /// reconnects (`request.header('last-event-id')`).
  final String? id;

  /// Asks the client to wait this long before reconnecting.
  final Duration? retry;
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

/// The body of `Response.sse`: [events] (each an [SseEvent] or a value sent
/// as an `update` event), a heartbeat comment every [heartbeat] while idle,
/// then [endStreamWith] (Laravel's `</stream>`, `null` for none). Ends early
/// when the application starts draining; cancelling (the client went away)
/// cancels [events].
Stream<List<int>> sseStream(
  Stream<Object?> events, {
  Object? endStreamWith = '</stream>',
  Duration? heartbeat = const Duration(seconds: 15),
}) {
  late final StreamController<List<int>> controller;
  StreamSubscription<Object?>? subscription;
  Timer? timer;
  var closed = false;

  void send(SseEvent event) {
    if (!closed) {
      controller.add(utf8.encode(event.encode()));
    }
  }

  Future<void> finish() async {
    if (closed) {
      return;
    }
    if (endStreamWith != null) {
      send(endStreamWith is SseEvent ? endStreamWith : SseEvent(endStreamWith));
    }
    closed = true;
    timer?.cancel();
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
      unawaited(drain?.future.then((_) => finish()));
    },
    onPause: () => subscription?.pause(),
    onResume: () => subscription?.resume(),
    onCancel: () async {
      // The client disconnected.
      closed = true;
      timer?.cancel();
      await subscription?.cancel();
    },
  );
  return controller.stream;
}

/// Handles an upgraded connection (`router.ws`).
typedef WebSocketHandler = FutureOr<void> Function(
  WebSocket socket,
  Request request,
);

/// Whether [request] asks to switch to the WebSocket protocol.
bool isWebSocketUpgrade(Request request) =>
    (request.header('upgrade') ?? '').toLowerCase() == 'websocket' &&
    (request.header('connection') ?? '').toLowerCase().contains('upgrade');
