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
    this.encryptionMasterKey,
    this.scaling = false,
    this.scalingDriver = 'database',
    this.scalingConnection,
    this.scalingPoll = const Duration(milliseconds: 100),
    this.serverId,
  });

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
  final String appKey;
  final String appSecret;

  /// Where `reverb` and `pusher` send events.
  final String? host;
  final int? port;
  final String scheme;

  /// Origins that may connect (`REVERB_ALLOWED_ORIGINS`, host patterns
  /// with `*`): every origin by default, as in Reverb.
  final List<String> allowedOrigins;

  /// Seconds of silence before a client should ping (sent to clients).
  final int activityTimeout;

  /// The largest message a client may send, in bytes.
  final int maxMessageSize;

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
