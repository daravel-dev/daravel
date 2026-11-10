import 'dart:async';
import 'dart:io';

/// A [ServerSocket] whose stream of connections ends only when [finish] is
/// called, while the socket under it can stop accepting earlier
/// ([stopAccepting]): what a graceful drain needs from `dart:io`.
///
/// [HttpServer] closes its idle connections as soon as the stream of the
/// socket it listens on ends, and a connection accepted a moment before,
/// whose request has not been read yet, counts as idle: closing the
/// socket, or `HttpServer.close`, closed it without a response. Here the
/// server keeps those connections while the socket accepts no new one, for
/// as long as the drain waits ([ServeOptions.drainGrace]).
///
/// It implements the interface of `dart:io` ([address], [port], [close],
/// and the stream), which a later SDK could widen: if a new member breaks
/// the build, implement it here (forwarding to [_inner]); `noSuchMethod`
/// is not to be used for that.
///
/// No TLS: the engine serves plain HTTP, TLS being ended in front of it (a
/// load balancer, a reverse proxy).
final class GracefulServerSocket extends StreamView<Socket>
    implements ServerSocket {
  GracefulServerSocket._(this._inner, this._connections)
    : super(_connections.stream);

  /// Binds [address]:[port] ([ServerSocket.bind], [shared] as there).
  static Future<GracefulServerSocket> bind(
    Object address,
    int port, {
    bool shared = false,
  }) async {
    // Bound first: nothing to leak if it fails.
    final inner = await ServerSocket.bind(address, port, shared: shared);
    // Closed by finish() (or close(), which HttpServer.close calls).
    // ignore: close_sinks
    final connections = StreamController<Socket>();
    final socket = GracefulServerSocket._(inner, connections);
    socket._subscription = inner.listen(
      (connection) {
        socket._accepted++;
        connections.add(connection);
      },
      onError: connections.addError,
      onDone: () => socket._accepting = false,
    );
    return socket;
  }

  final ServerSocket _inner;
  final StreamController<Socket> _connections;
  StreamSubscription<Socket>? _subscription;
  bool _accepting = true;
  int _accepted = 0;

  /// How many connections it accepted.
  int get accepted => _accepted;

  /// Whether new connections are accepted.
  bool get accepting => _accepting;

  /// Stops accepting new connections; those accepted stay with the server
  /// listening on this stream. Idempotent.
  Future<void> stopAccepting() async {
    if (!_accepting) {
      return;
    }
    _accepting = false;
    await _inner.close();
  }

  /// Ends the stream of connections (after [stopAccepting]): the server
  /// then closes its idle connections. Idempotent.
  Future<void> finish() async {
    await stopAccepting();
    await _subscription?.cancel();
    _subscription = null;
    if (!_connections.isClosed) {
      await _connections.close();
    }
  }

  @override
  InternetAddress get address => _inner.address;

  @override
  int get port => _inner.port;

  /// [stopAccepting] and [finish] at once (what [HttpServer.close] calls).
  @override
  Future<ServerSocket> close() async {
    await finish();
    return this;
  }
}
