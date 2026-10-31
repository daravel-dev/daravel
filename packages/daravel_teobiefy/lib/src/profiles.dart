import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:daravel/daravel.dart';

import 'crypto.dart';
import 'zstd_decoder.dart';

/// teobiefy-laravel-api-response 0.3 payload profiles (`Profile`): what is
/// done to the `data` of a response and to the body of a request.
enum TeobiefyProfile {
  plain('plain'),
  compressed('compressed'),
  encrypted('encrypted'),
  compressedEncrypted('compressed_encrypted'),
  signed('signed'),
  compressedSigned('compressed_signed');

  const TeobiefyProfile(this.label);

  /// The name in `config/teobiefy.php`.
  final String label;

  /// The profile called [name]; an [ArgumentError] for an unknown one.
  static TeobiefyProfile from(String name) => values.firstWhere(
    (profile) => profile.label == name,
    orElse: () => throw ArgumentError.value(name, 'profile', 'Unknown profile'),
  );

  bool get compresses =>
      this == compressed ||
      this == compressedEncrypted ||
      this == compressedSigned;
  bool get encrypts => this == encrypted || this == compressedEncrypted;
  bool get signs => this == signed || this == compressedSigned;
}

/// A body that cannot be read: `406 Invalid payload`.
final class TeobiefyInvalidPayload implements Exception {
  const TeobiefyInvalidPayload(this.message);
  final String message;
  @override
  String toString() => message;
}

/// `401 Invalid signature`.
final class TeobiefyInvalidSignature implements Exception {
  const TeobiefyInvalidSignature(this.message);
  final String message;
  @override
  String toString() => message;
}

/// `409 Replay detected`.
final class TeobiefyReplayDetected implements Exception {
  const TeobiefyReplayDetected(this.message);
  final String message;
  @override
  String toString() => message;
}

/// `413 Payload too large`.
final class TeobiefyPayloadTooLarge implements Exception {
  const TeobiefyPayloadTooLarge();
}

/// Keys by id, the one in use, and the single key without an id (`KeyRing`
/// and `SigningKeyRing`). Each key is base64, with or without `base64:`, or
/// raw text.
final class TeobiefyKeyRing {
  TeobiefyKeyRing({
    Map<String, String> keys = const {},
    this.activeKid,
    String? legacyKey,
  }) : _keys = {
         for (final MapEntry(:key, :value) in keys.entries)
           if (value.isNotEmpty) key: decodeMaterial(value),
       },
       _legacy = legacyKey == null || legacyKey.isEmpty
           ? null
           : decodeMaterial(legacyKey);

  final Map<String, Uint8List> _keys;
  final Uint8List? _legacy;
  final String? activeKid;

  static Uint8List decodeMaterial(String material) {
    final text = material.startsWith('base64:')
        ? material.substring('base64:'.length)
        : material;
    return TeobiefyCrypto.strictBase64(text) ??
        Uint8List.fromList(utf8.encode(text));
  }

  /// The key for new payloads and its id, `null` in single-key mode.
  (String?, Uint8List) active() {
    final kid = activeKid;
    if (kid != null && _keys.isNotEmpty) {
      final key = _keys[kid];
      if (key == null) {
        throw StateError('The active key [$kid] is not in the key ring.');
      }
      return (kid, key);
    }
    final legacy = _legacy;
    if (legacy == null) {
      throw StateError('Missing a Teobiefy key.');
    }
    return (null, legacy);
  }

  /// The key named by an envelope, or `null` when there is none.
  Uint8List? resolve(String? kid) => kid == null ? _legacy : _keys[kid];
}

/// The settings of [TeobiefyProfiles], named as `config/teobiefy.php`.
final class TeobiefyProfilesConfig implements ConfigSection {
  const TeobiefyProfilesConfig({
    this.cipher = 'xchacha20-poly1305',
    this.encryptionKey,
    this.encryptionKid,
    this.signingKey,
    this.signingKid,
    this.replayProtection = false,
    this.replayWindow = const Duration(seconds: 300),
    this.replayNonceTtl = const Duration(seconds: 600),
    this.replayPrefix = 'teobiefy:rp:',
    this.minCompressBytes = 1024,
    this.maxDecompressedBytes = 10485760,
  });

  /// `TEOBIEFY_ENCRYPTION_KEY`, `TEOBIEFY_ENCRYPTION_ACTIVE_KID`,
  /// `TEOBIEFY_SIGNING_KEY`, `TEOBIEFY_SIGNING_ACTIVE_KID`,
  /// `TEOBIEFY_REPLAY_PROTECTION`, and `TEOBIEFY_ENCRYPTION_DRIVER`.
  factory TeobiefyProfilesConfig.fromEnv(Env env) => TeobiefyProfilesConfig(
    cipher: env.string('TEOBIEFY_ENCRYPTION_DRIVER', 'xchacha20-poly1305'),
    encryptionKey: env.maybeString('TEOBIEFY_ENCRYPTION_KEY'),
    encryptionKid: env.maybeString('TEOBIEFY_ENCRYPTION_ACTIVE_KID'),
    signingKey: env.maybeString('TEOBIEFY_SIGNING_KEY'),
    signingKid: env.maybeString('TEOBIEFY_SIGNING_ACTIVE_KID'),
    replayProtection: env.boolean('TEOBIEFY_REPLAY_PROTECTION', false),
  );

  /// `xchacha20-poly1305`, `chacha20-poly1305-ietf` or `aes-256-gcm`.
  final String cipher;
  final String? encryptionKey;
  final String? encryptionKid;
  final String? signingKey;
  final String? signingKid;
  final bool replayProtection;
  final Duration replayWindow;
  final Duration replayNonceTtl;
  final String replayPrefix;

  /// Smaller responses are left as they are (`compression.min_bytes`).
  final int minCompressBytes;
  final int maxDecompressedBytes;

  /// Rejects an unknown cipher and a nonce kept for less than two windows.
  static Iterable<ConfigIssue> check(Env env, ConfigRepository config) sync* {
    final profiles = config.section<TeobiefyProfilesConfig>();
    if (!const {
      'xchacha20-poly1305',
      'chacha20-poly1305-ietf',
      'aes-256-gcm',
    }.contains(profiles.cipher)) {
      yield ConfigIssue(
        ConfigIssueLevel.error,
        'TEOBIEFY_ENCRYPTION_DRIVER=${profiles.cipher} is not supported.',
      );
    }
    if (profiles.replayNonceTtl < profiles.replayWindow * 2) {
      yield const ConfigIssue(
        ConfigIssueLevel.error,
        'Teobiefy: the replay nonce TTL must be at least two windows.',
      );
    }
  }

  @override
  String get key => 'teobiefy_profiles';

  @override
  Map<String, Object?> toMap() => {
    'cipher': cipher,
    'replay_protection': replayProtection,
  };
}

/// `PayloadTransformer`: applies a [TeobiefyProfile] to a response's `data`
/// and undoes it on a request.
///
/// Compressed responses are Zstandard frames of raw blocks
/// ([TeobiefyCrypto.zstdFrame]), which every decoder reads but which are not
/// smaller. Requests may carry any frame `ext-zstd` writes, read by
/// [zstdDecompress].
final class TeobiefyProfiles {
  TeobiefyProfiles(
    this.config, {
    required this.encryption,
    required this.signing,
    this.replayStore,
  });

  final TeobiefyProfilesConfig config;
  final TeobiefyKeyRing encryption;
  final TeobiefyKeyRing signing;

  /// Remembers replay nonces; needed with `replayProtection`.
  final CacheRepository? replayStore;

  static const List<String> metadataKeys = [
    'data_enc',
    'data_comp',
    'nonce',
    'cipher',
    'compression',
    'kid',
    'sig',
    'sig_alg',
    'sig_kid',
  ];

  bool _replayProtected(TeobiefyProfile profile) =>
      config.replayProtection && (profile.encrypts || profile.signs);

  /// [response] with its `data` replaced by the envelope of [profile].
  Future<Map<String, Object?>> transformResponse(
    Map<String, Object?> response,
    TeobiefyProfile profile,
  ) async {
    if (profile == TeobiefyProfile.plain) {
      return response;
    }
    var payload = Uint8List.fromList(utf8.encode(jsonEncode(response['data'])));
    final rest = {...response}..remove('data');
    if (_replayProtected(profile)) {
      payload = _wrapReplay(payload);
    }
    var compression = 'none';
    if (profile.compresses && payload.length >= config.minCompressBytes) {
      payload = TeobiefyCrypto.zstdFrame(payload);
      compression = 'zstd';
    }
    if (profile.encrypts) {
      final (kid, key) = encryption.active();
      final nonce = _randomNonce();
      return {
        ...rest,
        'data_enc': base64.encode(await encrypt(payload, nonce, key)),
        'nonce': base64.encode(nonce),
        'cipher': config.cipher,
        'compression': compression,
        'kid': ?kid,
      };
    }
    return {
      ...rest,
      'data_comp': base64.encode(payload),
      'compression': compression,
      if (profile.signs) ..._signature(payload),
    };
  }

  /// The JSON object [body] carries under [profile].
  Future<Map<String, Object?>> decodeRequest(
    Map<String, Object?> body,
    TeobiefyProfile profile,
  ) async {
    if (profile == TeobiefyProfile.plain) {
      return body;
    }
    final field = profile.encrypts ? 'data_enc' : 'data_comp';
    final encoded = _required(body, field);
    if (encoded.length > _maxEncodedChars) {
      throw const TeobiefyPayloadTooLarge();
    }
    var decoded = _base64(encoded, field);
    if (profile.signs) {
      _verify(decoded, body);
    }
    if (profile.encrypts) {
      decoded = await _decrypt(decoded, body);
    }
    if (profile.compresses && _compression(body) == 'zstd') {
      decoded = _decompress(decoded);
    }
    if (_replayProtected(profile)) {
      decoded = await _unwrapReplay(decoded);
    }
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(decoded));
    } on FormatException {
      throw const TeobiefyInvalidPayload('Payload is not valid JSON.');
    }
    if (json is! Map<String, Object?>) {
      throw const TeobiefyInvalidPayload('Payload JSON must be an object.');
    }
    return json;
  }

  /// The longest field a payload of [TeobiefyConfig.maxDecompressedBytes]
  /// can give: a replay envelope holds it as base64, plus the cipher's and
  /// the frame's overhead, all as base64. Longer ones are refused before
  /// the buffers of decoding and decrypting are allocated.
  int get _maxEncodedChars =>
      ((config.maxDecompressedBytes * 4 ~/ 3 + 4096) * 4) ~/ 3;

  String _required(Map<String, Object?> body, String key) =>
      switch (body[key]) {
        final String value when value.isNotEmpty => value,
        _ => throw TeobiefyInvalidPayload('Missing [$key] payload field.'),
      };

  Uint8List _base64(String value, String key) =>
      TeobiefyCrypto.strictBase64(value) ??
      (throw TeobiefyInvalidPayload('[$key] is not valid base64.'));

  String _compression(Map<String, Object?> body) {
    final compression = body['compression'] ?? 'zstd';
    if (compression != 'zstd' && compression != 'none') {
      throw TeobiefyInvalidPayload('Unsupported compression [$compression].');
    }
    return compression as String;
  }

  String? _optional(Map<String, Object?> body, String key) =>
      switch (body[key]) {
        final String value when value.isNotEmpty => value,
        _ => null,
      };

  // -- Encryption ------------------------------------------------------------

  Cipher get _cipher => switch (config.cipher) {
    'xchacha20-poly1305' => Xchacha20.poly1305Aead(),
    'chacha20-poly1305-ietf' => Chacha20.poly1305Aead(),
    'aes-256-gcm' => AesGcm.with256bits(),
    final other => throw StateError('Unsupported cipher [$other].'),
  };

  Uint8List _randomNonce() {
    final length = config.cipher == 'xchacha20-poly1305' ? 24 : 12;
    return Uint8List.fromList(_cipher.newNonce().sublist(0, length));
  }

  /// Ciphertext followed by the 16-byte tag, as both sodium and
  /// `encryptAesGcm` write it.
  Future<Uint8List> encrypt(
    List<int> payload,
    List<int> nonce,
    List<int> key,
  ) async {
    _assertKey(key);
    final box = await _cipher.encrypt(
      payload,
      secretKey: SecretKey(key),
      nonce: nonce,
    );
    return Uint8List.fromList([...box.cipherText, ...box.mac.bytes]);
  }

  void _assertKey(List<int> key) {
    if (key.length != 32) {
      throw StateError('A Teobiefy encryption key must be 32 bytes.');
    }
  }

  Future<Uint8List> _decrypt(
    Uint8List sealed,
    Map<String, Object?> body,
  ) async {
    final cipher = body['cipher'];
    if (cipher is String && cipher.isNotEmpty && cipher != config.cipher) {
      throw TeobiefyInvalidPayload(
        'Cipher [$cipher] does not match the route.',
      );
    }
    final nonce = _base64(_required(body, 'nonce'), 'nonce');
    final key = encryption.resolve(_optional(body, 'kid'));
    if (key == null) {
      throw const TeobiefyInvalidPayload('Unknown encryption key.');
    }
    _assertKey(key);
    if (sealed.length < 16) {
      throw const TeobiefyInvalidPayload('Unable to decrypt the payload.');
    }
    try {
      final clear = await _cipher.decrypt(
        SecretBox(
          sealed.sublist(0, sealed.length - 16),
          nonce: nonce,
          mac: Mac(sealed.sublist(sealed.length - 16)),
        ),
        secretKey: SecretKey(key),
      );
      return Uint8List.fromList(clear);
    } on Object {
      throw const TeobiefyInvalidPayload('Unable to decrypt the payload.');
    }
  }

  // -- Signing ---------------------------------------------------------------

  Map<String, Object?> _signature(List<int> payload) {
    final (kid, key) = signing.active();
    _assertSigningKey(key);
    return {
      'sig': base64.encode(
        crypto.Hmac(crypto.sha256, key).convert(payload).bytes,
      ),
      'sig_alg': 'hmac-sha256',
      'sig_kid': ?kid,
    };
  }

  void _assertSigningKey(List<int> key) {
    if (key.length < 32) {
      throw StateError('A Teobiefy signing key must be at least 32 bytes.');
    }
  }

  void _verify(Uint8List payload, Map<String, Object?> body) {
    final sig = _required(body, 'sig');
    final alg = _optional(body, 'sig_alg') ?? 'hmac-sha256';
    if (alg != 'hmac-sha256') {
      throw TeobiefyInvalidSignature('Disallowed signing algorithm [$alg].');
    }
    final given = TeobiefyCrypto.strictBase64(sig);
    if (given == null || given.isEmpty) {
      throw const TeobiefyInvalidSignature('Signature is not valid base64.');
    }
    final key = signing.resolve(_optional(body, 'sig_kid'));
    if (key == null) {
      throw const TeobiefyInvalidSignature('Unknown signing key.');
    }
    _assertSigningKey(key);
    final computed = crypto.Hmac(crypto.sha256, key).convert(payload).bytes;
    if (!constantTimeEquals(base64.encode(computed), base64.encode(given))) {
      throw const TeobiefyInvalidSignature('Signature verification failed.');
    }
  }

  // -- Replay protection -----------------------------------------------------

  Uint8List _wrapReplay(List<int> payload) {
    final seconds = Clock.now().millisecondsSinceEpoch ~/ 1000;
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'ts': seconds,
          'rnonce': base64.encode(TeobiefyCrypto.nonce()),
          'payload': base64.encode(payload),
        }),
      ),
    );
  }

  Future<Uint8List> _unwrapReplay(Uint8List wrapped) async {
    final Object? data;
    try {
      data = jsonDecode(utf8.decode(wrapped));
    } on FormatException {
      throw const TeobiefyInvalidPayload('Replay envelope is not valid JSON.');
    }
    if (data case {
      'ts': final int ts,
      'rnonce': final String rnonce,
      'payload': final String payload,
    }) {
      final inner = TeobiefyCrypto.strictBase64(payload);
      if (inner == null) {
        throw const TeobiefyInvalidPayload('Replay payload is not base64.');
      }
      await _assertFresh(ts, rnonce);
      return inner;
    }
    throw const TeobiefyInvalidPayload('Replay envelope is malformed.');
  }

  Future<void> _assertFresh(int timestamp, String rnonce) async {
    final now = Clock.now().millisecondsSinceEpoch ~/ 1000;
    if ((now - timestamp).abs() > config.replayWindow.inSeconds) {
      throw const TeobiefyReplayDetected(
        'Timestamp outside the replay window.',
      );
    }
    final store = replayStore;
    if (store == null) {
      throw StateError('Teobiefy replay protection needs a cache store.');
    }
    final digest = crypto.sha256.convert(utf8.encode(rnonce));
    final fresh = await store.add(
      '${config.replayPrefix}$digest',
      true,
      ttl: config.replayNonceTtl,
    );
    if (!fresh) {
      throw const TeobiefyReplayDetected('The replay nonce was already used.');
    }
  }

  // -- Zstandard -------------------------------------------------------------

  /// Reads any frame `ext-zstd` writes, up to [maxDecompressedBytes].
  Uint8List _decompress(Uint8List frame) {
    try {
      return zstdDecompress(frame, maxOutput: config.maxDecompressedBytes);
    } on ZstdTooLargeException {
      throw const TeobiefyPayloadTooLarge();
    } on ZstdFormatException {
      throw const TeobiefyInvalidPayload('Unable to decompress the payload.');
    }
  }
}

/// Laravel's `Str::is`: `*` matches anything, across `/` too.
bool _matches(String pattern, String value) {
  if (pattern == value) {
    return true;
  }
  final regex = pattern.split('*').map(RegExp.escape).join('.*');
  return RegExp('^$regex\$', dotAll: true).hasMatch(value);
}

/// `RouteProfileResolver`: the profile of a request, from a pattern on the
/// route's name or path, else [fallback].
TeobiefyProfile resolveTeobiefyProfile(
  Request request,
  Map<String, String> routeProfiles,
  TeobiefyProfile fallback,
) {
  final route = request.route;
  final candidates = [
    ?route?.routeName,
    ?route?.path,
    request.path,
    request.path.replaceFirst(RegExp('^/'), ''),
    ?route?.path.replaceFirst(RegExp('^/'), ''),
  ];
  for (final MapEntry(key: pattern, value: profile) in routeProfiles.entries) {
    if (candidates.any((candidate) => _matches(pattern, candidate))) {
      return TeobiefyProfile.from(profile);
    }
  }
  return fallback;
}

/// `teobiefy.profile`: applies payload profiles to a route's request and
/// response (`PayloadDecryptMiddleware` and `ApiResponse`).
///
/// `teobiefy.profile:encrypted` sets the profile of both directions, and
/// `teobiefy.profile:encrypted,plain` of the response and the request, as
/// the `ResponseProfile` and `RequestProfile` attributes do. Without
/// parameters the patterns of `withTeobiefyProfiles` decide.
final class TeobiefyProfileMiddleware implements Middleware {
  const TeobiefyProfileMiddleware({
    required this.routeResponses,
    required this.routeRequests,
    required this.defaultResponse,
    required this.defaultRequest,
    this.response,
    this.request,
  });

  final Map<String, String> routeResponses;
  final Map<String, String> routeRequests;
  final TeobiefyProfile defaultResponse;
  final TeobiefyProfile defaultRequest;
  final TeobiefyProfile? response;
  final TeobiefyProfile? request;

  @override
  Future<Response> handle(Request request, Next next) async {
    final profiles = Container.current.make<TeobiefyProfiles>();
    final requestProfile =
        this.request ??
        resolveTeobiefyProfile(request, routeRequests, defaultRequest);
    Response? refused;
    if (requestProfile != TeobiefyProfile.plain) {
      refused = await _decode(request, profiles, requestProfile);
    }
    // A refusal goes through the response profile too, as upstream's
    // `api()->response()`.
    final answer = refused ?? await next(request);
    final responseProfile =
        response ??
        resolveTeobiefyProfile(request, routeResponses, defaultResponse);
    return responseProfile == TeobiefyProfile.plain
        ? answer
        : _encode(answer, profiles, responseProfile);
  }

  Future<Response?> _decode(
    Request request,
    TeobiefyProfiles profiles,
    TeobiefyProfile profile,
  ) async {
    Response refuse(int status, String message, Object error) {
      Log.warning('Teobiefy: $error');
      return Response.json({
        'status': status,
        'message': message,
        'data': <Object?>[],
      }, status: status);
    }

    final body = await request.body();
    try {
      final input = <String, Object?>{
        if (body is Map<Object?, Object?>)
          for (final MapEntry(:key, :value) in body.entries) '$key': value,
      };
      final decoded = await profiles.decodeRequest(input, profile);
      request.replace({
        for (final MapEntry(:key, :value) in input.entries)
          if (!TeobiefyProfiles.metadataKeys.contains(key)) key: value,
        ...decoded,
      });
      return null;
    } on TeobiefyPayloadTooLarge catch (error) {
      return refuse(413, 'Payload too large', error);
    } on TeobiefyReplayDetected catch (error) {
      return refuse(409, 'Replay detected', error);
    } on TeobiefyInvalidSignature catch (error) {
      return refuse(
        401,
        'Invalid signature',
        error,
      ).withHeader('www-authenticate', 'TeobiefySig');
    } on TeobiefyInvalidPayload catch (error) {
      return refuse(406, 'Invalid payload', error);
    }
  }

  Future<Response> _encode(
    Response response,
    TeobiefyProfiles profiles,
    TeobiefyProfile profile,
  ) async {
    if (!(response.headers.first('content-type') ?? '').contains('json')) {
      return response;
    }
    // Read once: a stream body cannot be read twice.
    final raw = await response.bodyBytes();
    Response unchanged() => Response(
      status: response.status,
      headers: response.headers,
      body: BytesBody(raw),
    );
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(raw));
    } on FormatException {
      return unchanged();
    }
    if (json is! Map<String, Object?> || !json.containsKey('data')) {
      return unchanged();
    }
    final envelope = await profiles.transformResponse(json, profile);
    return Response(
      status: response.status,
      headers: response.headers,
      body: BytesBody(Uint8List.fromList(utf8.encode(jsonEncode(envelope)))),
    );
  }
}
