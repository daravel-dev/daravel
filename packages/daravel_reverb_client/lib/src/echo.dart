import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:web_socket_channel/web_socket_channel.dart';

import 'auth.dart';
import 'auth_support.dart';
import 'secretbox.dart';

/// The client's version, sent in the connection URL (`version=`).
const String reverbClientVersion = '1.27.0';

/// Where the connection to the server is.
enum EchoConnectionState {
  /// Not started.
  initialized,

  /// Opening the WebSocket, or waiting for `pusher:connection_established`.
  connecting,

  /// Established: [Echo.socketId] is set.
  connected,

  /// Lost; reconnecting after a backoff.
  unavailable,

  /// Closed by [Echo.disconnect], or refused for good (`4000`-`4099`).
  disconnected,
}

/// Opens a WebSocket: `WebSocketChannel.connect` by default, which works on
/// the VM, in Flutter (mobile, desktop) and on the web.
typedef EchoConnector = WebSocketChannel Function(Uri uri);

/// Called with an event's data: its JSON object, or `{'data': value}` for
/// another value.
typedef EchoListener = void Function(Map<String, Object?> data);

/// A presence member's `user_info`.
typedef EchoMemberListener = void Function(Map<String, Object?> member);

/// A Pusher protocol 7 client after Laravel Echo, for Laravel Reverb,
/// Daravel and Pusher: public, private, encrypted and presence channels,
/// whispers, cache channels, pings and reconnects with backoff.
final class Echo {
  /// A client of the application [key] on the server at [host]
  /// (`wss://ws.example.com`, `ws://127.0.0.1:8080`), under [path] when
  /// the server has a prefix (`REVERB_SERVER_PATH`). Private, encrypted and
  /// presence channels need [auth]. [namespace] prefixes the event names of
  /// [EchoChannel.listen] as Laravel Echo's does (`App.Events`); a name
  /// starting with `.` is taken as it is.
  ///
  /// It connects at once unless [autoConnect] is false.
  Echo.reverb({
    required this.key,
    required String host,
    String path = '',
    this.auth,
    this.namespace = 'App.Events',
    EchoConnector? connector,
    this.reconnectBase = const Duration(seconds: 1),
    this.reconnectMax = const Duration(seconds: 30),
    this.pongTimeout = const Duration(seconds: 30),
    Duration? activityTimeout,
    Random? random,
    bool autoConnect = true,
  }) : uri = _endpoint(host, path, key),
       _connector = connector ?? WebSocketChannel.connect,
       _clientActivity = activityTimeout ?? const Duration(seconds: 120),
       _random = random ?? Random() {
    if (autoConnect) {
      connect();
    }
  }

  static Uri _endpoint(String host, String path, String key) {
    final base = Uri.parse(host.contains('://') ? host : 'wss://$host');
    final prefix = path.isEmpty || path == '/'
        ? ''
        : (path.startsWith('/') ? path : '/$path').replaceAll(
            RegExp(r'/$'),
            '',
          );
    return base.replace(
      path: '$prefix/app/$key',
      queryParameters: {
        'protocol': '7',
        'client': 'daravel_reverb_client',
        'version': reverbClientVersion,
        'flash': 'false',
      },
    );
  }

  /// The application key.
  final String key;

  /// The WebSocket URL.
  final Uri uri;

  /// Authorizes private, encrypted and presence channels.
  final EchoAuth? auth;

  /// The prefix of event names ([EchoChannel.listen]), or null.
  final String? namespace;

  /// The first reconnect delay; doubled after each failed try.
  final Duration reconnectBase;

  /// The longest reconnect delay.
  final Duration reconnectMax;

  /// How long a `pusher:ping` waits for its `pusher:pong`.
  final Duration pongTimeout;

  final EchoConnector _connector;
  final Duration _clientActivity;
  final Random _random;

  final Map<String, EchoChannel> _channels = {};
  final StreamController<EchoConnectionState> _states =
      StreamController<EchoConnectionState>.broadcast(sync: true);
  final StreamController<Map<String, Object?>> _errors =
      StreamController<Map<String, Object?>>.broadcast(sync: true);

  WebSocketChannel? _socket;
  StreamSubscription<Object?>? _subscription;
  EchoConnectionState _state = EchoConnectionState.initialized;
  String? _socketId;
  Duration _activity = const Duration(seconds: 120);
  Timer? _activityTimer;
  Timer? _pongTimer;
  Timer? _reconnectTimer;
  int _attempts = 0;
  bool _closing = false;

  /// The connection's socket id once connected: the `X-Socket-ID` header
  /// that leaves this client out of a broadcast (`toOthers`).
  String? get socketId => _socketId;

  /// Where the connection is.
  EchoConnectionState get connectionState => _state;

  /// Every change of [connectionState].
  Stream<EchoConnectionState> get onConnectionStateChange => _states.stream;

  /// `pusher:error` frames (`{code, message}`), failed authorizations
  /// (`{channel, status}`), errors of the WebSocket
  /// (`{type: 'WebSocketError', error}`, as pusher-js emits them) and
  /// events of an encrypted channel that could not be opened
  /// (`{type: 'DecryptionError', channel, event}`; the event is dropped).
  Stream<Map<String, Object?>> get onError => _errors.stream;

  /// Opens the connection (done by the constructor unless `autoConnect`
  /// is false); after [disconnect], opens it again.
  void connect() {
    if (_state == EchoConnectionState.connecting ||
        _state == EchoConnectionState.connected) {
      return;
    }
    _closing = false;
    _open();
  }

  /// Closes the connection for good; channels are kept, for [connect].
  Future<void> disconnect() async {
    _closing = true;
    _reconnectTimer?.cancel();
    _stopTimers();
    final socket = _socket;
    _socket = null;
    await _subscription?.cancel();
    _subscription = null;
    await socket?.sink.close(1000);
    _socketId = null;
    // The authorizer's HTTP client; made again if [connect] follows.
    if (auth case final ClosableEchoAuth closable) {
      closable.close();
    }
    _setState(EchoConnectionState.disconnected);
  }

  /// A public channel ([name] as it is: `orders`, `cache-prices`).
  EchoChannel channel(String name) =>
      _channel(name, () => EchoChannel._(this, name));

  /// The private channel `private-<name>`.
  EchoPrivateChannel private(String name) => _channel(
    'private-$name',
    () => EchoPrivateChannel._(this, 'private-$name'),
  ) as EchoPrivateChannel;

  /// The end-to-end encrypted channel `private-encrypted-<name>`: events
  /// are decrypted with the `shared_secret` of its authorization.
  EchoEncryptedChannel encryptedPrivate(String name) => _channel(
    'private-encrypted-$name',
    () => EchoEncryptedChannel._(this, 'private-encrypted-$name'),
  ) as EchoEncryptedChannel;

  /// The presence channel `presence-<name>`.
  EchoPresenceChannel join(String name) => _channel(
    'presence-$name',
    () => EchoPresenceChannel._(this, 'presence-$name'),
  ) as EchoPresenceChannel;

  /// Leaves `<name>` in every form (public, private, encrypted, presence).
  void leave(String name) {
    for (final full in [
      name,
      'private-$name',
      'private-encrypted-$name',
      'presence-$name',
    ]) {
      leaveChannel(full);
    }
  }

  /// Leaves the channel called [name] exactly.
  ///
  /// While its subscription is on its way, the channel is only marked
  /// cancelled, and left (`pusher:unsubscribe`) once the server confirms
  /// it, as pusher-js does: an unsubscribe sent earlier could reach a
  /// server still subscribing, and the subscription would stay there.
  void leaveChannel(String name) {
    final channel = _channels[name];
    if (channel == null) {
      return;
    }
    if (channel._pending) {
      channel._cancelled = true;
      return;
    }
    _channels.remove(name);
    if (channel.subscribed) {
      _send({
        'event': 'pusher:unsubscribe',
        'data': {'channel': name},
      });
    }
  }

  /// Leaves every channel.
  void leaveAll() {
    for (final name in [..._channels.keys]) {
      leaveChannel(name);
    }
  }

  /// The channels joined, by name (not those left while subscribing).
  Map<String, EchoChannel> get channels => Map.unmodifiable({
    for (final MapEntry(:key, :value) in _channels.entries)
      if (!value._cancelled) key: value,
  });

  /// The Pusher name of [event] as Laravel Echo writes it: [namespace]
  /// prefixed, dots as backslashes; a leading `.` or `\` takes it as it is.
  String formatEvent(String event) {
    if (event.startsWith('.') || event.startsWith(r'\')) {
      return event.substring(1);
    }
    final full = namespace == null || namespace!.isEmpty
        ? event
        : '$namespace.$event';
    return full.replaceAll('.', r'\');
  }

  EchoChannel _channel(String name, EchoChannel Function() create) {
    final existing = _channels[name];
    if (existing != null) {
      // Joined again while a cancelled subscription is on its way: it
      // stands (pusher-js reinstateSubscription).
      existing._cancelled = false;
      return existing;
    }
    final channel = create();
    _channels[name] = channel;
    if (_state == EchoConnectionState.connected) {
      unawaited(channel._subscribe());
    }
    return channel;
  }

  void _setState(EchoConnectionState state) {
    if (_state == state) {
      return;
    }
    _state = state;
    _emit(() {
      if (!_states.isClosed) {
        _states.add(state);
      }
    });
  }

  void _error(Map<String, Object?> error) => _emit(() {
    if (!_errors.isClosed) {
      _errors.add(error);
    }
  });

  final List<void Function()> _queued = [];
  bool _emitting = false;

  /// Runs [add], one event at a time. The controllers are synchronous, so
  /// a listener that changes the connection (calling [connect] on
  /// `unavailable`) would add while a controller is still firing, which
  /// throws; such an event waits and follows in order.
  void _emit(void Function() add) {
    if (_emitting) {
      _queued.add(add);
      return;
    }
    _emitting = true;
    try {
      add();
      while (_queued.isNotEmpty) {
        _queued.removeAt(0)();
      }
    } finally {
      _emitting = false;
    }
  }

  void _open() {
    // A reconnect may be waiting ([connect] while unavailable), and a
    // previous socket may still be open: one connection at a time, or
    // every event would arrive twice.
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    final previous = _socket;
    final previousSubscription = _subscription;
    _socket = null;
    _subscription = null;
    if (previous != null) {
      unawaited(previousSubscription?.cancel());
      unawaited(previous.sink.close(1000));
    }
    _setState(EchoConnectionState.connecting);
    final WebSocketChannel socket;
    try {
      socket = _connector(uri);
    } on Object {
      _lost(null);
      return;
    }
    _socket = socket;
    // Each callback checks that its socket is still the current one: a
    // socket replaced or closed here must not touch the new connection.
    _subscription = socket.stream.listen(
      (message) {
        if (identical(_socket, socket)) {
          _onMessage(message);
        }
      },
      onDone: () {
        if (identical(_socket, socket)) {
          _lost(socket.closeCode);
        }
      },
      onError: (Object error) {
        if (identical(_socket, socket)) {
          _error({'type': 'WebSocketError', 'error': '$error'});
        }
      },
      cancelOnError: false,
    );
    socket.ready.catchError((Object _) {});
  }

  void _lost(int? code) {
    _stopTimers();
    _socket = null;
    _subscription = null;
    _socketId = null;
    for (final channel in _channels.values) {
      channel
        .._subscribed = false
        .._pending = false;
    }
    if (_closing) {
      return;
    }
    // Pusher: 4000-4099 do not reconnect, 4200-4299 reconnect at once,
    // anything else after a backoff.
    if (code != null && code >= 4000 && code < 4100) {
      _setState(EchoConnectionState.disconnected);
      return;
    }
    final delay = code != null && code >= 4200 && code < 4300
        ? Duration.zero
        : _backoff();
    // The timer before the state: a listener of `unavailable` may call
    // [connect], which must find this timer to cancel it, or the timer
    // would later replace the connection that call opened.
    _reconnectTimer = Timer(delay, () {
      _reconnectTimer = null;
      if (!_closing && _state == EchoConnectionState.unavailable) {
        _open();
      }
    });
    _setState(EchoConnectionState.unavailable);
  }

  /// The next reconnect delay: exponential, capped, with jitter (half to
  /// all of it) so clients do not all come back at once.
  Duration _backoff() {
    final exp = reconnectBase * pow(2, _attempts.clamp(0, 16)).toInt();
    final capped = exp > reconnectMax ? reconnectMax : exp;
    _attempts++;
    final ms = capped.inMilliseconds;
    return Duration(milliseconds: ms ~/ 2 + _random.nextInt(ms ~/ 2 + 1));
  }

  void _stopTimers() {
    _activityTimer?.cancel();
    _pongTimer?.cancel();
    _activityTimer = null;
    _pongTimer = null;
  }

  void _resetActivity() {
    _activityTimer?.cancel();
    _activityTimer = Timer(_activity, () {
      _send({'event': 'pusher:ping', 'data': <String, Object?>{}});
      _pongTimer?.cancel();
      _pongTimer = Timer(pongTimeout, () {
        // No pong: the connection is gone without a close.
        final socket = _socket;
        unawaited(_subscription?.cancel());
        unawaited(socket?.sink.close(4201));
        _lost(4201);
      });
    });
  }

  void _send(Map<String, Object?> frame) {
    _socket?.sink.add(jsonEncode(frame));
  }

  void _onMessage(Object? message) {
    if (message is! String) {
      return;
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(message);
    } on FormatException {
      return;
    }
    if (decoded is! Map<String, Object?>) {
      return;
    }
    _resetActivity();
    final event = decoded['event'];
    final data = _data(decoded['data']);
    final channelName = decoded['channel'];
    switch (event) {
      case 'pusher:connection_established':
        final socketId = data['socket_id'];
        _socketId = socketId is String ? socketId : null;
        _activity = _activityFrom(data['activity_timeout'], _clientActivity);
        _attempts = 0;
        _setState(EchoConnectionState.connected);
        _resetActivity();
        // Channels left while subscribing on the lost connection are gone
        // (pusher-js subscribeAll).
        _channels.removeWhere((_, channel) => channel._cancelled);
        for (final channel in [..._channels.values]) {
          unawaited(channel._subscribe());
        }
      case 'pusher:ping':
        _send({'event': 'pusher:pong', 'data': <String, Object?>{}});
      case 'pusher:pong':
        _pongTimer?.cancel();
        _pongTimer = null;
      case 'pusher:error':
        _error(data);
      default:
        if (channelName is String && event is String) {
          _channels[channelName]?._receive(event, decoded['data']);
        }
    }
  }

  /// The ping interval: the server's `activity_timeout` (seconds) when it
  /// is shorter than [client], at least one second; a value that is not a
  /// finite positive number is ignored (zero would ping without a pause,
  /// and `1e400` is infinite).
  static Duration _activityFrom(Object? seconds, Duration client) {
    if (seconds is! num || !seconds.isFinite || seconds <= 0) {
      return client;
    }
    final most = client.inMilliseconds;
    final ms = min(max((seconds * 1000).round(), min(1000, most)), most);
    return Duration(milliseconds: ms);
  }

  static Map<String, Object?> _data(Object? raw) {
    var value = raw;
    if (value is String) {
      try {
        value = jsonDecode(value);
      } on FormatException {
        return {'data': raw};
      }
    }
    return value is Map<String, Object?> ? value : {'data': value};
  }
}

/// A public channel (also the base of the others): its event listeners.
base class EchoChannel {
  EchoChannel._(this._echo, this.name);

  final Echo _echo;

  /// The channel's Pusher name (`orders`, `private-orders.7`).
  final String name;

  final Map<String, List<EchoListener>> _listeners = {};
  final List<void Function(String event, Map<String, Object?> data)> _all = [];
  final List<void Function()> _onSubscribed = [];
  final List<void Function(Object error)> _onError = [];
  bool _subscribed = false;

  /// A subscription is on its way (authorizing, or sent and not yet
  /// confirmed).
  bool _pending = false;

  /// Left while [_pending]: unsubscribed once confirmed.
  bool _cancelled = false;

  /// Whether the server confirmed the subscription.
  bool get subscribed => _subscribed;

  /// Calls [callback] with each [event] (named as Laravel Echo names it:
  /// `OrderShipped` is `App\Events\OrderShipped`, `.order.shipped` is
  /// `order.shipped`).
  EchoChannel listen(String event, EchoListener callback) {
    _listeners.putIfAbsent(_echo.formatEvent(event), () => []).add(callback);
    return this;
  }

  /// Calls [callback] with every event of the channel.
  EchoChannel listenToAll(
    void Function(String event, Map<String, Object?> data) callback,
  ) {
    _all.add(callback);
    return this;
  }

  /// Stops [callback] (or every listener) for [event].
  EchoChannel stopListening(String event, [EchoListener? callback]) {
    final name = _echo.formatEvent(event);
    if (callback == null) {
      _listeners.remove(name);
    } else {
      _listeners[name]?.remove(callback);
    }
    return this;
  }

  /// Calls [callback] once subscribed (again after each reconnect).
  EchoChannel subscribedTo(void Function() callback) {
    _onSubscribed.add(callback);
    if (_subscribed) {
      callback();
    }
    return this;
  }

  /// Calls [callback] when the subscription fails (authorization refused,
  /// `pusher:subscription_error`).
  EchoChannel error(void Function(Object error) callback) {
    _onError.add(callback);
    return this;
  }

  Future<Map<String, Object?>> _authorization() async =>
      const <String, Object?>{};

  Future<void> _subscribe() async {
    final socketId = _echo.socketId;
    if (socketId == null) {
      return;
    }
    _pending = true;
    final Map<String, Object?> authorization;
    try {
      authorization = await _authorization();
    } on Object catch (error) {
      _pending = false;
      if (_cancelled) {
        _echo.leaveChannel(name);
        return;
      }
      _echo._error({
        'channel': name,
        'status': error is EchoAuthException ? error.status : 0,
      });
      for (final callback in _onError) {
        callback(error);
      }
      return;
    }
    // The connection changed while authorizing: the next one subscribes.
    if (_echo.socketId != socketId || !_echo._channels.containsKey(name)) {
      return;
    }
    // Left while authorizing: nothing was sent, so nothing to undo.
    if (_cancelled) {
      _pending = false;
      _echo.leaveChannel(name);
      return;
    }
    _echo._send({
      'event': 'pusher:subscribe',
      'data': {'channel': name, ...authorization},
    });
  }

  void _receive(String event, Object? raw) {
    switch (event) {
      case 'pusher_internal:subscription_succeeded':
        _pending = false;
        _subscribed = true;
        if (_cancelled) {
          // Left while subscribing: leave now, and tell no listener.
          _echo.leaveChannel(name);
          return;
        }
        _succeeded(Echo._data(raw));
        for (final callback in [..._onSubscribed]) {
          callback();
        }
        return;
      case 'pusher:subscription_error':
        _pending = false;
        if (_cancelled) {
          _echo.leaveChannel(name);
          return;
        }
        for (final callback in _onError) {
          callback(Echo._data(raw));
        }
        return;
    }
    if (_internal(event, raw)) {
      return;
    }
    final data = _decode(event, raw);
    if (data == null) {
      return;
    }
    for (final callback in [...?_listeners[event]]) {
      callback(data);
    }
    for (final callback in [..._all]) {
      callback(event, data);
    }
  }

  void _succeeded(Map<String, Object?> data) {}

  bool _internal(String event, Object? raw) => false;

  Map<String, Object?>? _decode(String event, Object? raw) => Echo._data(raw);
}

/// A private channel: authorized, and able to whisper (`client-` events)
/// to the other members.
base class EchoPrivateChannel extends EchoChannel {
  EchoPrivateChannel._(super.echo, super.name) : super._();

  @override
  Future<Map<String, Object?>> _authorization() async {
    final authorizer = _echo.auth;
    if (authorizer == null) {
      throw StateError('$name needs Echo.reverb(auth: ...).');
    }
    final answer = checkedAuthorization(
      name,
      await authorizer.authorize(_echo.socketId!, name),
      0,
    );
    return {
      'auth': answer['auth'],
      if (answer['channel_data'] != null)
        'channel_data': answer['channel_data'],
    };
  }

  /// Sends `client-<event>` with [data] to the channel's other members
  /// (the server must accept client events).
  EchoPrivateChannel whisper(String event, Map<String, Object?> data) {
    _echo._send({'event': 'client-$event', 'channel': name, 'data': data});
    return this;
  }

  /// Calls [callback] with each broadcast notification on the channel
  /// (Laravel's `BroadcastNotificationCreated`, as Echo's `notification`).
  EchoPrivateChannel notification(EchoListener callback) {
    listen(
      r'.Illuminate\Notifications\Events\BroadcastNotificationCreated',
      callback,
    );
    return this;
  }

  /// Calls [callback] with each whisper [event] of the others.
  EchoPrivateChannel listenForWhisper(String event, EchoListener callback) {
    listen('.client-$event', callback);
    return this;
  }
}

/// An end-to-end encrypted channel (`private-encrypted-`): each event is
/// opened with the key of the authorization's `shared_secret`
/// (XSalsa20-Poly1305), as pusher-js does. Whispers are not supported.
final class EchoEncryptedChannel extends EchoPrivateChannel {
  EchoEncryptedChannel._(super.echo, super.name) : super._();

  List<int>? _key;

  @override
  Future<Map<String, Object?>> _authorization() async {
    final authorizer = _echo.auth;
    if (authorizer == null) {
      throw StateError('$name needs Echo.reverb(auth: ...).');
    }
    // Checked again for an authorizer of the application's own; the
    // built-in ones checked it with the HTTP status.
    final answer = checkedAuthorization(
      name,
      await authorizer.authorize(_echo.socketId!, name),
      0,
    );
    // A key that is not 32 bytes is refused there, before subscribing: it
    // used to subscribe, and every event failed to open.
    _key = base64.decode(answer['shared_secret']! as String);
    return {'auth': answer['auth']};
  }

  @override
  EchoPrivateChannel whisper(String event, Map<String, Object?> data) =>
      throw UnsupportedError('Encrypted channels do not support whispers.');

  /// Opens an event, or drops it (null) and reports it on [Echo.onError]
  /// when it is not a `{ciphertext, nonce}` this channel's key opens, as
  /// pusher-js logs and drops it. A malformed frame used to throw out of
  /// the socket's listener. (Our server relays no client events on
  /// encrypted channels, as Pusher; such a frame comes from a broadcast or
  /// another server.)
  @override
  Map<String, Object?>? _decode(String event, Object? raw) {
    final key = _key;
    final envelope = Echo._data(raw);
    final ciphertext = envelope['ciphertext'];
    final nonce = envelope['nonce'];
    Map<String, Object?>? opened;
    if (key != null && ciphertext is String && nonce is String) {
      try {
        final plain = Secretbox.open(
          base64.decode(ciphertext),
          base64.decode(nonce),
          key,
        );
        opened = plain == null ? null : Echo._data(utf8.decode(plain));
      } on FormatException {
        opened = null;
      }
    }
    if (opened == null) {
      _echo._error({
        'type': 'DecryptionError',
        'channel': name,
        'event': event,
      });
    }
    return opened;
  }
}

/// A presence channel: who is here, who joins and who leaves.
final class EchoPresenceChannel extends EchoPrivateChannel {
  EchoPresenceChannel._(super.echo, super.name) : super._();

  final Map<String, Map<String, Object?>> _members = {};
  final List<void Function(List<Map<String, Object?>> members)> _here = [];
  final List<EchoMemberListener> _joining = [];
  final List<EchoMemberListener> _leaving = [];

  /// The members now (their `user_info`).
  List<Map<String, Object?>> get members => [..._members.values];

  /// Calls [callback] with every member once subscribed (and after each
  /// reconnect).
  EchoPresenceChannel here(
    void Function(List<Map<String, Object?>> members) callback,
  ) {
    _here.add(callback);
    if (subscribed) {
      callback(members);
    }
    return this;
  }

  /// Calls [callback] with each member who joins.
  EchoPresenceChannel joining(EchoMemberListener callback) {
    _joining.add(callback);
    return this;
  }

  /// Calls [callback] with each member who leaves.
  EchoPresenceChannel leaving(EchoMemberListener callback) {
    _leaving.add(callback);
    return this;
  }

  @override
  void _succeeded(Map<String, Object?> data) {
    _members.clear();
    final presence = data['presence'];
    if (presence is Map<String, Object?>) {
      final hash = presence['hash'];
      if (hash is Map<String, Object?>) {
        for (final MapEntry(:key, :value) in hash.entries) {
          _members[key] = value is Map<String, Object?> ? value : {'id': key};
        }
      }
    }
    for (final callback in [..._here]) {
      callback(members);
    }
  }

  @override
  bool _internal(String event, Object? raw) {
    final data = Echo._data(raw);
    final id = '${data['user_id']}';
    switch (event) {
      case 'pusher_internal:member_added':
        final info = data['user_info'];
        final member = info is Map<String, Object?> ? info : {'id': id};
        // The server sends one join per user; a repeat only updates.
        final fresh = !_members.containsKey(id);
        _members[id] = member;
        if (fresh) {
          for (final callback in [..._joining]) {
            callback(member);
          }
        }
        return true;
      case 'pusher_internal:member_removed':
        final member = _members.remove(id);
        if (member != null) {
          for (final callback in [..._leaving]) {
            callback(member);
          }
        }
        return true;
    }
    return false;
  }
}
