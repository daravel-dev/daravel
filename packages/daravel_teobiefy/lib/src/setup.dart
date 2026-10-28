import 'dart:typed_data';

import 'package:daravel/daravel.dart';

import 'crypto.dart';
import 'middleware.dart';
import 'sessions.dart';

/// teobiefy's settings, under the names the Laravel application reads (`config/app.php`), so one `.env` serves both:
/// `LIBSODIUM_SESSION_TTL` (seconds, 1800), `LIBSODIUM_PAYLOAD_V2_ENABLED`
/// (false), `LIBSODIUM_LEGACY_KEY_ENABLED` (false) and
/// `LIBSODIUM_LEGACY_KEY`.
final class TeobiefyConfig implements ConfigSection {
  const TeobiefyConfig({
    this.sessionTtl = const Duration(seconds: 1800),
    this.payloadV2 = false,
    this.legacyKeyEnabled = false,
    this.legacyKey = '',
    this.strictPayload = false,
  });

  factory TeobiefyConfig.fromEnv(Env env) => TeobiefyConfig(
    sessionTtl: Duration(seconds: env.integer('LIBSODIUM_SESSION_TTL', 1800)),
    payloadV2: env.boolean('LIBSODIUM_PAYLOAD_V2_ENABLED', false),
    legacyKeyEnabled: env.boolean('LIBSODIUM_LEGACY_KEY_ENABLED', false),
    legacyKey: env.string('LIBSODIUM_LEGACY_KEY', ''),
    strictPayload: env.boolean('LIBSODIUM_STRICT_PAYLOAD', false),
  );

  final Duration sessionTtl;

  /// Only the decrypted payload reaches the handler: clear keys sent beside
  /// `data_enc` are dropped, and a clear body from a client that holds a
  /// session is `406`. Off by default, as the Laravel application merges
  /// clear keys and accepts clear bodies; turn it on once every client
  /// encrypts everything (`LIBSODIUM_STRICT_PAYLOAD`).
  final bool strictPayload;

  /// Responses seal the zstd bytes directly (`enc_v: 2`) instead of their
  /// base64; only for clients that recognise it.
  final bool payloadV2;

  /// Accept the old static key for clients without a session. That key was
  /// shipped to browsers and must be treated as public: a bridge during a
  /// rollout, never a protection.
  final bool legacyKeyEnabled;
  final String legacyKey;

  /// Warns while the legacy key is accepted; fails when it is not a key.
  static Iterable<ConfigIssue> check(Env env, ConfigRepository config) {
    final teobiefy = config.section<TeobiefyConfig>();
    if (!teobiefy.legacyKeyEnabled) {
      return const [];
    }
    final key = TeobiefyCrypto.strictBase64(teobiefy.legacyKey);
    return [
      if (key == null || key.length != 32)
        const ConfigIssue(
          ConfigIssueLevel.error,
          'Teobiefy: LIBSODIUM_LEGACY_KEY_ENABLED is true but '
          'LIBSODIUM_LEGACY_KEY is not a base64 32-byte key.',
        )
      else
        const ConfigIssue(
          ConfigIssueLevel.warning,
          'Teobiefy: LIBSODIUM_LEGACY_KEY_ENABLED accepts the static key, '
          'which clients have seen; disable it once every client handshakes.',
        ),
    ];
  }

  @override
  String get key => 'teobiefy';

  @override
  Map<String, Object?> toMap() => {
    'session_ttl': sessionTtl.inSeconds,
    'payload_v2': payloadV2,
    'legacy_key_enabled': legacyKeyEnabled,
    'legacy_key': legacyKey.isEmpty ? '' : '********',
    'strict_payload': strictPayload,
  };
}

/// The sessions and settings the middleware and the handshake share.
final class TeobiefyService {
  TeobiefyService(this.sessions, this.config)
    : legacyKey = config.legacyKeyEnabled
          ? switch (TeobiefyCrypto.strictBase64(config.legacyKey)) {
              final Uint8List key when key.length == 32 => key,
              _ => null,
            }
          : null;

  final TeobiefySessions sessions;
  final TeobiefyConfig config;

  /// The static key when it is accepted, else null.
  final Uint8List? legacyKey;
}

/// `withTeobiefy()` on the application builder.
extension TeobiefyApplicationBuilder on ApplicationBuilder {
  /// Adds teobiefy's v1 protocol: [TeobiefyConfig] from `.env`, the
  /// `teobiefy` middleware and [Teobiefy.handshake]. Sessions are kept in
  /// the default cache store, or in the `process` store when the default
  /// keeps a copy per isolate (a handshake on one worker must hold on the
  /// others).
  ApplicationBuilder withTeobiefy() =>
      withConfig<TeobiefyConfig>(TeobiefyConfig.fromEnv)
          .withConfigCheck(TeobiefyConfig.check)
          .withBindings(
            (container) => container.singleton<TeobiefyService>((c) {
              final config = c
                  .make<ConfigRepository>()
                  .section<TeobiefyConfig>();
              final cache = c.make<CacheManager>();
              final store = cache.store();
              return TeobiefyService(
                TeobiefySessions(
                  store.store.scope == StateScope.isolate
                      ? cache.store('process')
                      : store,
                  ttl: config.sessionTtl,
                ),
                config,
              );
            }),
          )
          .withMiddleware(
            (middleware) =>
                middleware.alias('teobiefy', const TeobiefyMiddleware()),
          );
}

/// teobiefy from anywhere in a request.
abstract final class Teobiefy {
  static TeobiefyService get service =>
      Container.current.make<TeobiefyService>();

  /// Set on the request by [handshake], so the middleware leaves its
  /// answer in clear.
  static const String handshakeAttribute = 'teobiefy.handshake';

  /// `POST /api/v1/session-key` (`SessionKeyController@store`): the
  /// client's X25519 public key in, the server's and a session id out.
  /// Unauthenticated by design (public endpoints encrypt too); limit it as
  /// the Laravel route does:
  ///
  /// ```dart
  /// router.post('/api/v1/session-key', Teobiefy.handshake)
  ///     .middleware(const ['throttle:30,1'])
  ///     .name('session-key.store');
  /// ```
  static Future<Response> handshake(Request request) async {
    request.attributes[handshakeAttribute] = true;
    final data = await request.validate({
      'client_public_key': 'required|string|max:64',
    });
    final TeobiefyHandshake session;
    try {
      session = await service.sessions.establish(
        data.string('client_public_key'),
      );
    } on ArgumentError catch (error) {
      return api(422, '${error.message}', null);
    }
    return api(200, 'Sesi enkripsi berhasil dibuat.', {
      'session_id': session.sessionId,
      'server_public_key': session.serverPublicKey,
      'expires_in': session.expiresIn,
    });
  }

  /// `409` asking the client to handshake again, as `SessionKeyService::
  /// requiredResponse()`.
  static Response sessionKeyRequired() => Response.json({
    'status': 409,
    'message': 'Sesi enkripsi tidak tersedia atau telah kedaluwarsa.',
    'data': null,
    'type': 'SESSION_KEY_REQUIRED',
  }, status: 409);

  /// `406` for a body that does not decrypt. (The Laravel middleware
  /// calls `api()->error(406, ...)`, whose arguments are
  /// message and data, and so answers 500; this is the 406 it means.)
  static Response invalidPayload() => api(406, 'Invalid payload', null);

  /// obiefy/api-response's `api($status, $message, $data)` with the
  /// Laravel application's settings: `status`, `message`, `data`, and
  /// `data_count` for non-empty arrays and objects; the HTTP status
  /// matches.
  static Response api(int status, String message, Object? data) =>
      Response.json({
        'status': status,
        'message': message,
        'data': data,
        if (data case Map<Object?, Object?>(isNotEmpty: true))
          'data_count': data.length
        else if (data case List<Object?>(isNotEmpty: true))
          'data_count': data.length,
      }, status: status);
}
