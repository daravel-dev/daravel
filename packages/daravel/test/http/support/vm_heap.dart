import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// The Dart heap of another process, read through its VM service (a
/// process started with `--enable-vm-service=0
/// --disable-service-auth-codes`): JSON-RPC 2.0 over a WebSocket, the two
/// calls the memory tests need, without `package:vm_service`.
final class VmHeap {
  VmHeap._(this._socket, this._isolate, this._replies);

  final WebSocket _socket;
  final String _isolate;
  final Map<String, Completer<Map<String, Object?>>> _replies;
  var _next = 0;

  /// The line the VM prints on stdout once its service listens.
  static final RegExp listening = RegExp(
    r'VM service is listening on (http://[^\s]+)',
  );

  /// Connects to the service at [http] (from [listening]) and picks the
  /// process's first isolate (the guard server runs one).
  static Future<VmHeap> connect(String http) async {
    final uri = Uri.parse(http);
    // Closed by [close], with the VmHeap that keeps it.
    // ignore: close_sinks
    final socket = await WebSocket.connect(
      uri.replace(scheme: 'ws', path: '${uri.path}ws').toString(),
    ).timeout(const Duration(seconds: 10));
    final replies = <String, Completer<Map<String, Object?>>>{};
    socket.listen((Object? message) {
      final reply = jsonDecode(message! as String) as Map<String, Object?>;
      final id = reply['id'];
      if (id is String) {
        replies.remove(id)?.complete(reply);
      }
    });
    final vm = await VmHeap._(socket, '', replies)._call('getVM', {});
    final isolates = vm['isolates']! as List<Object?>;
    final first = (isolates.first! as Map<String, Object?>)['id']! as String;
    return VmHeap._(socket, first, replies);
  }

  Future<Map<String, Object?>> _call(
    String method,
    Map<String, Object?> params,
  ) async {
    final id = '${_next++}';
    final reply = Completer<Map<String, Object?>>();
    _replies[id] = reply;
    _socket.add(
      jsonEncode({
        'jsonrpc': '2.0',
        'id': id,
        'method': method,
        'params': params,
      }),
    );
    final answer = await reply.future.timeout(const Duration(seconds: 30));
    final result = answer['result'];
    if (result is! Map<String, Object?>) {
      throw StateError('VM service $method failed: ${answer['error']}');
    }
    return result;
  }

  /// The bytes the isolate's heap holds after a full collection: live
  /// data, not what the allocator keeps for later (as resident memory
  /// does).
  Future<int> usedAfterGc() async {
    await _call('getAllocationProfile', {'isolateId': _isolate, 'gc': true});
    final usage = await _call('getMemoryUsage', {'isolateId': _isolate});
    return usage['heapUsage']! as int;
  }

  Future<void> close() => _socket.close();
}
