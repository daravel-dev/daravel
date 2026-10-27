import 'dart:async';
import 'dart:convert';

import 'package:daravel/daravel.dart';

import 'client.dart';
import 'connection.dart';
import 'resp.dart';

/// One stream entry: its id and fields.
typedef _Entry = ({String id, Map<String, String> fields});

/// Server-sent events that survive a reconnect: each one is kept in a
/// Redis stream (`XADD ... MAXLEN ~ maxLength`), its stream id is the
/// event's `id:`, and a client coming back with `Last-Event-ID` first gets
/// what it missed (`XRANGE`), then the live events.
///
/// ```dart
/// router.get('/orders/events', (request) =>
///     Response.sse(Redis.events('orders').since(request)));
///
/// await Redis.events('orders').publish({'id': 7}, event: 'created');
/// ```
///
/// Every listener of a channel in an isolate shares one `XREAD BLOCK`
/// connection, started with the first and closed with the last.
final class RedisEventStream {
  RedisEventStream(this.client, this.key, {this.maxLength = 1000});

  final RedisClient client;

  /// The stream (`<REDIS_PREFIX>sse:<channel>` from [Redis.events]).
  final String key;

  /// Events kept for clients that come back (about this many; `~`).
  final int maxLength;

  static final Expando<Map<String, _Tail>> _tails = Expando();

  /// Adds an event; returns its id.
  Future<String> publish(Object? data, {String event = 'update'}) async =>
      (await client.command([
            'XADD',
            key,
            'MAXLEN',
            '~',
            maxLength,
            '*',
            'event',
            event,
            'data',
            jsonEncode(data),
          ]))!
          as String;

  /// The events after the request's `Last-Event-ID`, then live ones; live
  /// ones only without the header.
  Stream<SseEvent> since(Request request) =>
      listen(lastEventId: request.header('last-event-id'));

  /// The events after [lastEventId] (none before them when null), then the
  /// live ones, each once and in order.
  Stream<SseEvent> listen({String? lastEventId}) {
    final tails = _tails[client] ??= {};
    final tail = tails[key] ??= _Tail(client, key, () => tails.remove(key));
    late final StreamController<SseEvent> out;
    StreamSubscription<_Entry>? live;
    var last = lastEventId;
    var caughtUp = false;
    final waiting = <_Entry>[];

    void emit(_Entry entry) {
      if (last != null && !_after(entry.id, last!)) {
        return; // seen in the catch-up
      }
      last = entry.id;
      final data = entry.fields['data'];
      out.add(
        SseEvent(
          data == null ? null : _decode(data),
          event: entry.fields['event'] ?? 'update',
          id: entry.id,
        ),
      );
    }

    out = StreamController<SseEvent>(
      onListen: () async {
        live = tail.entries.listen(
          (entry) => caughtUp ? emit(entry) : waiting.add(entry),
          onError: out.addError,
        );
        try {
          // Live events start after this point; the catch-up reaches it.
          await tail.started;
          if (lastEventId != null && _isId(lastEventId)) {
            final missed =
                (await client.command(['XRANGE', key, '($lastEventId', '+']))!
                    as List;
            missed.map(_entry).forEach(emit);
          }
        } on Object catch (error, stack) {
          out.addError(error, stack);
        }
        caughtUp = true;
        waiting
          ..forEach(emit)
          ..clear();
      },
      onCancel: () async {
        await live?.cancel();
        await out.close();
      },
    );
    return out.stream;
  }

  static Object? _decode(String data) {
    try {
      return jsonDecode(data);
    } on FormatException {
      return data;
    }
  }

  static bool _isId(String id) => RegExp(r'^\d+-\d+$').hasMatch(id);

  /// Whether stream id [a] comes after [b].
  static bool _after(String a, String b) {
    final [aMs, aSeq] = a.split('-').map(int.parse).toList();
    final [bMs, bSeq] = b.split('-').map(int.parse).toList();
    return aMs > bMs || (aMs == bMs && aSeq > bSeq);
  }

  static _Entry _entry(Object? raw) {
    final [id, fields] = raw! as List;
    final list = (fields as List?) ?? const [];
    return (
      id: id! as String,
      fields: {
        for (var i = 0; i + 1 < list.length; i += 2)
          '${list[i]}': '${list[i + 1]}',
      },
    );
  }
}

/// The live end of one stream in this isolate: one `XREAD BLOCK` loop for
/// all its listeners.
final class _Tail {
  _Tail(this.client, this.key, this._onIdle) {
    _controller = StreamController<_Entry>.broadcast(
      onListen: () => unawaited(_run()),
      onCancel: _stop,
    );
  }

  final RedisClient client;
  final String key;
  final void Function() _onIdle;
  late final StreamController<_Entry> _controller;
  final Completer<void> _started = Completer<void>();
  RedisConnection? _connection;
  bool _stopped = false;

  Stream<_Entry> get entries => _controller.stream;

  /// Completes once the loop knows where it starts.
  Future<void> get started => _started.future;

  Future<void> _run() async {
    try {
      final newest =
          (await client.command(['XREVRANGE', key, '+', '-', 'COUNT', 1]))!
              as List;
      var last = newest.isEmpty
          ? '0-0'
          : RedisEventStream._entry(newest.first).id;
      _started.complete();
      while (!_stopped) {
        try {
          final connection = _connection ??= await client.dedicated(key: key);
          final reply = await connection.send([
            'XREAD',
            'BLOCK',
            5000,
            'COUNT',
            100,
            'STREAMS',
            key,
            last,
          ], timeout: const Duration(seconds: 10));
          if (reply case [[_, final List<Object?> entries], ...]) {
            for (final raw in entries) {
              final entry = RedisEventStream._entry(raw);
              last = entry.id;
              _controller.add(entry);
            }
          }
        } on RedisConnectionException {
          _connection = null;
          if (!_stopped) {
            await Future<void>.delayed(const Duration(milliseconds: 200));
          }
        }
      }
    } on Object catch (error, stack) {
      if (!_started.isCompleted) {
        _started.completeError(error, stack);
      }
      if (!_stopped) {
        _controller.addError(error, stack);
      }
    }
  }

  Future<void> _stop() async {
    _stopped = true;
    _onIdle();
    final connection = _connection;
    _connection = null;
    await connection?.close();
  }
}
