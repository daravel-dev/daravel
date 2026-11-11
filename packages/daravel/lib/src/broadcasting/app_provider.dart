import 'dart:async';

import 'broadcast_config.dart';

/// Reverb's per-application rate limiting (`rate_limiting` of an app).
final class BroadcastRateLimit {
  /// [maxAttempts] messages per [decay] window; past them a message is
  /// refused with `4301`, the connection closed too when [terminate].
  const BroadcastRateLimit({
    this.maxAttempts = 60,
    this.decay = const Duration(seconds: 60),
    this.terminate = false,
  });

  /// Messages per window.
  final int maxAttempts;

  /// The window.
  final Duration decay;

  /// Whether a client past the limit is disconnected.
  final bool terminate;
}

/// One Pusher application a server serves, as an entry of Reverb's
/// `reverb.apps.apps` (Blueprint #135): its credentials and limits.
final class BroadcastApp {
  /// The application [id], [key] and [secret], with its limits.
  const BroadcastApp({
    required this.id,
    required this.key,
    required this.secret,
    this.allowedOrigins = const ['*'],
    this.maxConnections = 0,
    this.maxMessageSize = 10000,
    this.activityTimeout = 30,
    this.encryptionMasterKey,
    this.rateLimiting,
  });

  /// The application of [config] (`REVERB_APP_ID`, `REVERB_APP_KEY`, ...).
  factory BroadcastApp.fromConfig(BroadcastConfig config) => BroadcastApp(
    id: config.appId,
    key: config.appKey,
    secret: config.appSecret,
    allowedOrigins: config.allowedOrigins,
    maxConnections: config.maxConnections,
    maxMessageSize: config.maxMessageSize,
    activityTimeout: config.activityTimeout,
    encryptionMasterKey: config.encryptionMasterKey,
    rateLimiting: config.rateLimiting
        ? BroadcastRateLimit(
            maxAttempts: config.rateLimitMaxAttempts,
            decay: config.rateLimitDecay,
            terminate: config.rateLimitTerminate,
          )
        : null,
  );

  /// The id in `/apps/{id}/...`.
  final String id;

  /// The key in `/app/{key}` (public: clients send it).
  final String key;

  /// The secret that signs channel authorizations and HTTP API calls.
  final String secret;

  /// Origin host patterns allowed to connect (`*` for any).
  final List<String> allowedOrigins;

  /// The most open connections across the server's isolates (`0` for no
  /// limit); past it a client gets `4004`.
  final int maxConnections;

  /// The largest message a client may send, in bytes.
  final int maxMessageSize;

  /// Seconds between pings (`activity_timeout`).
  final int activityTimeout;

  /// The 32-byte key of `private-encrypted-` channels.
  final List<int>? encryptionMasterKey;

  /// Its rate limiting, or null for none.
  final BroadcastRateLimit? rateLimiting;

  /// The app without its secrets, for dashboards and logs.
  Map<String, Object?> toPublicMap() => {
    'id': id,
    'key': key,
    'allowed_origins': allowedOrigins,
    'max_connections': maxConnections,
    'max_message_size': maxMessageSize,
    'activity_timeout': activityTimeout,
    'rate_limiting': rateLimiting != null,
  };
}

/// Where a Pusher server finds the applications it serves: by the key a
/// client connects with, and by the id an HTTP API call names.
///
/// The default ([SingleAppProvider]) serves the one application of the
/// `REVERB_APP_*` settings; `withBroadcasting(apps:)` gives another, such
/// as one reading a table of tenants.
abstract interface class BroadcastAppProvider {
  /// The application with this [key], or null (the client gets `4001`).
  FutureOr<BroadcastApp?> byKey(String key);

  /// The application with this [id], or null (the call gets `404`).
  FutureOr<BroadcastApp?> byId(String id);
}

/// One application, from the broadcasting settings: what a server served
/// before applications could be provided.
final class SingleAppProvider implements BroadcastAppProvider {
  /// The provider of [app].
  const SingleAppProvider(this.app);

  /// The provider of the application in [config]; none when the server
  /// does not serve (`REVERB_APP_KEY` or `REVERB_APP_SECRET` empty).
  factory SingleAppProvider.fromConfig(BroadcastConfig config) =>
      SingleAppProvider(config.serves ? BroadcastApp.fromConfig(config) : null);

  /// The application, or null when none is served.
  final BroadcastApp? app;

  @override
  BroadcastApp? byKey(String key) => app?.key == key ? app : null;

  @override
  BroadcastApp? byId(String id) => app?.id == id ? app : null;
}

/// Several applications given in code: `withBroadcasting(apps:
/// ListAppProvider([...]))`.
final class ListAppProvider implements BroadcastAppProvider {
  /// The provider of [apps]; keys and ids must be unique.
  ListAppProvider(Iterable<BroadcastApp> apps)
    : _byKey = {for (final app in apps) app.key: app},
      _byId = {for (final app in apps) app.id: app} {
    if (_byKey.length != _byId.length) {
      throw ArgumentError('Broadcast apps need unique ids and keys.');
    }
  }

  final Map<String, BroadcastApp> _byKey;
  final Map<String, BroadcastApp> _byId;

  /// Every application.
  Iterable<BroadcastApp> get apps => _byId.values;

  @override
  BroadcastApp? byKey(String key) => _byKey[key];

  @override
  BroadcastApp? byId(String id) => _byId[id];
}
