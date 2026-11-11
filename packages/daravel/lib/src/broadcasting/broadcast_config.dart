import 'dart:convert';

import '../foundation/config.dart';
import '../foundation/env.dart';
import '../foundation/exceptions.dart';

/// Broadcasting, from the keys of Laravel 12's `config/broadcasting.php`
/// and `config/reverb.php`, so one `.env` serves both frameworks.
///
/// `BROADCAST_CONNECTION` picks where events go:
///
/// - `daravel` (the default): this server, which speaks the Pusher
///   protocol as Laravel Reverb does (`withBroadcasting`), to every worker
///   isolate;
/// - `reverb`: a Reverb (or Daravel) server elsewhere, at `REVERB_HOST`,
///   through its HTTP API;
/// - `pusher`: Pusher Channels (`PUSHER_*`), the same way;
/// - `log`: written to the log; `null`: dropped.
final class BroadcastConfig implements ConfigSection {
  /// Broadcasting settings; usually from `.env` ([BroadcastConfig.fromEnv]).
  const BroadcastConfig({
    this.connection = 'daravel',
    this.appId = '',
    this.appKey = '',
    this.appSecret = '',
    this.host,
    this.port,
    this.scheme = 'https',
    this.allowedOrigins = const ['*'],
    this.activityTimeout = 30,
    this.maxMessageSize = 10000,
    this.maxBufferedBytes = defaultMaxBufferedBytes,
    this.maxChannelsPerConnection = 100,
    this.clientEventsPerSecond = 10,
    this.validateChannelNames = true,
    this.maxConnections = 0,
    this.rateLimiting = false,
    this.rateLimitMaxAttempts = 60,
    this.rateLimitDecay = const Duration(seconds: 60),
    this.rateLimitTerminate = false,
    this.afterCommit = true,
    this.drainSpread = const Duration(seconds: 2),
    this.pulseIngestInterval = const Duration(seconds: 15),
    this.encryptionMasterKey,
    this.scaling = false,
    this.scalingDriver = 'database',
    this.scalingConnection,
    this.scalingPoll = const Duration(milliseconds: 100),
    this.serverId,
  });

  /// The settings in `BROADCAST_*` and `REVERB_*`/`PUSHER_*`.
  factory BroadcastConfig.fromEnv(Env env) {
    final connection = env.string('BROADCAST_CONNECTION', 'daravel');
    final pusher = connection == 'pusher';
    String? read(String name) =>
        env.maybeString(pusher ? 'PUSHER_$name' : 'REVERB_$name');
    final cluster = env.maybeString('PUSHER_APP_CLUSTER');
    final scheme = read('SCHEME') ?? 'https';
    return BroadcastConfig(
      connection: connection,
      appId: read('APP_ID') ?? '',
      appKey: read('APP_KEY') ?? '',
      appSecret: read('APP_SECRET') ?? '',
      host:
          read('HOST') ??
          (pusher ? 'api-${cluster ?? 'mt1'}.pusher.com' : null),
      port: int.tryParse(read('PORT') ?? '') ?? (scheme == 'https' ? 443 : 80),
      scheme: scheme,
      allowedOrigins: env.list('REVERB_ALLOWED_ORIGINS', const ['*']),
      activityTimeout: env.integer('REVERB_APP_ACTIVITY_TIMEOUT', 30),
      maxMessageSize: env.integer('REVERB_APP_MAX_MESSAGE_SIZE', 10000),
      maxBufferedBytes: env.integer(
        'REVERB_MAX_BUFFERED_BYTES',
        defaultMaxBufferedBytes,
      ),
      maxChannelsPerConnection: env.integer(
        'REVERB_APP_MAX_CHANNELS_PER_CONNECTION',
        100,
      ),
      clientEventsPerSecond: env.integer(
        'REVERB_APP_CLIENT_EVENTS_PER_SECOND',
        10,
      ),
      validateChannelNames: env.boolean(
        'REVERB_APP_VALIDATE_CHANNEL_NAMES',
        true,
      ),
      maxConnections: env.integer('REVERB_APP_MAX_CONNECTIONS', 0),
      rateLimiting: env.boolean('REVERB_APP_RATE_LIMITING_ENABLED', false),
      rateLimitMaxAttempts: env.integer(
        'REVERB_APP_RATE_LIMIT_MAX_ATTEMPTS',
        60,
      ),
      rateLimitDecay: Duration(
        seconds: env.integer('REVERB_APP_RATE_LIMIT_DECAY_SECONDS', 60),
      ),
      rateLimitTerminate: env.boolean('REVERB_APP_RATE_LIMIT_TERMINATE', false),
      afterCommit: env.boolean('BROADCAST_AFTER_COMMIT', true),
      pulseIngestInterval: Duration(
        seconds: env.integer('REVERB_PULSE_INGEST_INTERVAL', 15),
      ),
      drainSpread: env.duration(
        'REVERB_DRAIN_SPREAD',
        const Duration(seconds: 2),
      ),
      encryptionMasterKey: _masterKey(
        env.maybeString(
          pusher
              ? 'PUSHER_ENCRYPTION_MASTER_KEY_BASE64'
              : 'REVERB_ENCRYPTION_MASTER_KEY_BASE64',
        ),
      ),
      scaling: env.boolean('REVERB_SCALING_ENABLED', false),
      scalingDriver: env.string('REVERB_SCALING_DRIVER', 'database'),
      scalingConnection: env.maybeString('REVERB_SCALING_CONNECTION'),
      scalingPoll: env.duration(
        'REVERB_SCALING_POLL',
        const Duration(milliseconds: 100),
      ),
      serverId: env.maybeString('REVERB_SERVER_ID'),
    );
  }

  /// `daravel`, `reverb`, `pusher`, `log` or `null`.
  final String connection;

  /// The application's id, key and secret (`REVERB_APP_ID`, `_KEY`,
  /// `_SECRET`): the key is public (clients connect with it), the secret
  /// signs channel authorizations and API requests.
  final String appId;

  /// The application key clients connect with.
  final String appKey;

  /// The secret signing channel authorizations.
  final String appSecret;

  /// Where `reverb` and `pusher` send events.
  final String? host;

  /// The port of the WebSocket server; the scheme's default when null.
  final int? port;

  /// `http` or `https`.
  final String scheme;

  /// Origins that may connect (`REVERB_ALLOWED_ORIGINS`, host patterns
  /// with `*`): every origin by default, as in Reverb.
  final List<String> allowedOrigins;

  /// Seconds of silence before a client should ping (sent to clients).
  final int activityTimeout;

  /// The largest message a client may send, in bytes.
  final int maxMessageSize;

  /// How many bytes may wait to be sent to one client before it is closed
  /// with 4100 as too slow to read (`REVERB_MAX_BUFFERED_BYTES`, 1 MiB):
  /// a paused tab or a phone on a bad network otherwise made the server
  /// queue every frame published to its channels in memory.
  final int maxBufferedBytes;

  /// [maxBufferedBytes] unless `REVERB_MAX_BUFFERED_BYTES` says otherwise.
  static const int defaultMaxBufferedBytes = 1 << 20;

  /// How many channels one connection may be subscribed to at once
  /// (`REVERB_APP_MAX_CHANNELS_PER_CONNECTION`, 100; 0 for no limit). A
  /// subscription past it is refused with `pusher:error` 4300 and the
  /// connection stays open. Each channel costs memory in every isolate
  /// and in the coordinator, and public channels need no authorization.
  final int maxChannelsPerConnection;

  /// How many client events (`client-*`, Echo's whisper) one connection
  /// may send per second (`REVERB_APP_CLIENT_EVENTS_PER_SECOND`, 10 as
  /// Pusher Channels; 0 for no limit). Past it an event is dropped and the
  /// sender gets `pusher:error` 4301, as from Pusher.
  final int clientEventsPerSecond;

  /// Whether channel names must follow Pusher's rules
  /// (`REVERB_APP_VALIDATE_CHANNEL_NAMES`, true): at most 164 characters
  /// of `A-Z a-z 0-9 _ - = @ , . ;`. A subscription to any other name is
  /// refused with `pusher:error` 4300.
  final bool validateChannelNames;

  /// The most connections the application may have open on this server
  /// at once, every worker isolate counted (`REVERB_APP_MAX_CONNECTIONS`,
  /// as Reverb's `max_connections`; 0 for no limit). A connection past it
  /// gets `pusher:error` 4004 "Application is over connection quota" and is
  /// closed, before `pusher:connection_established`.
  final int maxConnections;

  /// Whether each connection's messages are rate limited, as Reverb's
  /// `rate_limiting` (`REVERB_APP_RATE_LIMITING_ENABLED`, false): every
  /// message a client sends counts, `pusher:ping` included (WebSocket
  /// control frames do not). Past [rateLimitMaxAttempts] within
  /// [rateLimitDecay] the message is refused with `pusher:error` 4301
  /// "Rate limit exceeded", and the connection is closed when
  /// [rateLimitTerminate]. Kept per connection, in its isolate.
  final bool rateLimiting;

  /// Messages allowed per window (`REVERB_APP_RATE_LIMIT_MAX_ATTEMPTS`,
  /// 60).
  final int rateLimitMaxAttempts;

  /// The rate limiting window (`REVERB_APP_RATE_LIMIT_DECAY_SECONDS`, 60).
  final Duration rateLimitDecay;

  /// Whether a connection over the limit is closed
  /// (`REVERB_APP_RATE_LIMIT_TERMINATE`, false).
  final bool rateLimitTerminate;

  /// Whether broadcasts made inside a database transaction wait for its
  /// commit and are dropped on rollback (`BROADCAST_AFTER_COMMIT`, true),
  /// so clients never hear of a change that did not happen.
  final bool afterCommit;

  /// Over how long a shutting-down server spreads closing its Pusher
  /// connections (`REVERB_DRAIN_SPREAD`, 2 s; bounded by the shutdown
  /// timeout), so the clients do not all reconnect at the same instant.
  final Duration drainSpread;

  /// How often each worker isolate reports its Pusher activity to the
  /// coordinator while it has connections (`REVERB_PULSE_INGEST_INTERVAL`,
  /// seconds, 15 as Reverb), for Pulse and the Reverb dashboard.
  final Duration pulseIngestInterval;

  /// The key of end-to-end encrypted channels (`private-encrypted-…`):
  /// 32 bytes, `REVERB_ENCRYPTION_MASTER_KEY_BASE64` (or `PUSHER_…`), as
  /// pusher-php-server's `encryption_master_key_base64`.
  final List<int>? encryptionMasterKey;

  static List<int>? _masterKey(String? base64Key) {
    if (base64Key == null || base64Key.isEmpty) {
      return null;
    }
    final List<int> key;
    try {
      key = base64.decode(base64Key);
    } on FormatException {
      throw const ConfigException(
        'The broadcasting encryption master key must be valid base64.',
      );
    }
    if (key.length != 32) {
      throw const ConfigException(
        'The broadcasting encryption master key must be 32 bytes '
        '(openssl rand -base64 32).',
      );
    }
    return key;
  }

  /// Several servers (machines, or processes) serve the same clients
  /// (`REVERB_SCALING_ENABLED`, as in Reverb): events, channel members and
  /// cache channels are shared through the database
  /// (`REVERB_SCALING_CONNECTION`, default the default connection) instead
  /// of Reverb's Redis.
  final bool scaling;

  /// What the servers share through (`REVERB_SCALING_DRIVER`): `database`,
  /// or `redis` with package:daravel_redis.
  final String scalingDriver;

  /// The connection relaying messages between servers, when there are
  /// several.
  final String? scalingConnection;

  /// How often a server reads the other servers' events when the database
  /// cannot notify it (PostgreSQL does, through `LISTEN`).
  final Duration scalingPoll;

  /// This server's name among the others (`REVERB_SERVER_ID`); by default
  /// the host name and process id, shared by its worker isolates.
  final String? serverId;

  /// Whether this server answers Pusher clients: it has a key and secret.
  bool get serves => appKey.isNotEmpty && appSecret.isNotEmpty;

  @override
  String get key => 'broadcasting';

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'connection': connection,
    'app_id': appId,
    'key': appKey,
    'secret': appSecret.isEmpty ? '' : '********',
    'host': host,
    'port': port,
    'scheme': scheme,
    'allowed_origins': allowedOrigins,
    'activity_timeout': activityTimeout,
    'max_message_size': maxMessageSize,
    'max_buffered_bytes': maxBufferedBytes,
    'max_channels_per_connection': maxChannelsPerConnection,
    'client_events_per_second': clientEventsPerSecond,
    'validate_channel_names': validateChannelNames,
    'max_connections': maxConnections,
    'rate_limiting': {
      'enabled': rateLimiting,
      'max_attempts': rateLimitMaxAttempts,
      'decay_seconds': rateLimitDecay.inSeconds,
      'terminate_on_limit': rateLimitTerminate,
    },
    'after_commit': afterCommit,
    'drain_spread_ms': drainSpread.inMilliseconds,
    'pulse_ingest_interval_s': pulseIngestInterval.inSeconds,
    'encryption_master_key': encryptionMasterKey == null ? null : '********',
    'scaling': {
      'enabled': scaling,
      'driver': scalingDriver,
      'connection': scalingConnection,
      'poll_ms': scalingPoll.inMilliseconds,
      'server_id': serverId,
    },
  };
}
