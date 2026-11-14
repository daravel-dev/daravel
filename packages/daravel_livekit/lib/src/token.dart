import 'package:daravel/daravel.dart';

import 'grants.dart';

/// A LiveKit access token (the `AccessToken` of LiveKit's server SDKs): a
/// JWT signed with the API secret, whose issuer is the API key.
///
/// ```dart
/// final jwt = await LivekitToken(
///   apiKey: key,
///   apiSecret: secret,
///   identity: user.uuid,
///   name: user.name,
///   ttl: const Duration(hours: 2),
///   video: VideoGrant(roomJoin: true, room: 'class-7a', roomAdmin: isTeacher),
/// ).toJwt();
/// ```
final class LivekitToken {
  /// An access token for a participant, signed with [apiKey].
  const LivekitToken({
    required this.apiKey,
    required this.apiSecret,
    this.identity,
    this.name,
    this.metadata,
    this.attributes,
    this.ttl = const Duration(hours: 4),
    this.video,
    this.sha256,
  });

  /// The API key, the token's issuer.
  final String apiKey;

  /// The API secret signing it.
  final String apiSecret;

  /// The participant (`sub` and `jti`); required to join a room.
  final String? identity;

  /// The participant's display name.
  final String? name;

  /// Free-form text the other participants see (JSON, typically).
  final String? metadata;

  /// Attributes of the participant.
  final Map<String, String>? attributes;

  /// How long the token is valid (4 hours, as LiveKit's SDKs).
  final Duration ttl;

  /// What the participant may do.
  final VideoGrant? video;

  /// The base64 SHA-256 of a webhook body this token vouches for.
  final String? sha256;

  /// This token with [grant] merged into its video grant.
  LivekitToken withGrant(VideoGrant grant) => LivekitToken(
    apiKey: apiKey,
    apiSecret: apiSecret,
    identity: identity,
    name: name,
    metadata: metadata,
    attributes: attributes,
    ttl: ttl,
    video: video?.merge(grant) ?? grant,
    sha256: sha256,
  );

  /// The claims, as LiveKit's SDKs write them: `sub`/`jti`, `exp`, `nbf`,
  /// `iat`, `iss`, then `name`, `metadata`, `sha256`, `video` and
  /// `attributes` when set.
  Map<String, Object?> get claims {
    if (video?.roomJoin == true && (identity == null || identity!.isEmpty)) {
      throw StateError('Identity is required to join but has not been set.');
    }
    // The identity is the participant's id in every room and webhook; a
    // control character in it (a line break in a log line, a NUL) is
    // refused rather than signed.
    if (identity case final String id
        when id.codeUnits.any((c) => c < 0x20 || c == 0x7F)) {
      throw ArgumentError.value(
        id,
        'identity',
        'must not hold control characters',
      );
    }
    if (ttl <= Duration.zero) {
      throw ArgumentError.value(ttl, 'ttl', 'must be positive');
    }
    final now = Clock.now().toUtc().millisecondsSinceEpoch ~/ 1000;
    final grant = video?.toJson() ?? const <String, Object?>{};
    return {
      if (identity case final String id when id.isNotEmpty) ...{
        'sub': id,
        'jti': id,
      },
      'exp': now + ttl.inSeconds,
      'nbf': now,
      'iat': now,
      'iss': apiKey,
      if (name case final String n when n.isNotEmpty) 'name': n,
      if (metadata case final String m when m.isNotEmpty) 'metadata': m,
      if (sha256 case final String s when s.isNotEmpty) 'sha256': s,
      if (grant.isNotEmpty) 'video': grant,
      if (attributes case final Map<String, String> a when a.isNotEmpty)
        'attributes': a,
    };
  }

  /// The signed JWT (HS256). [StateError] without a secret: HS256 over an
  /// empty key signs, and LiveKit would refuse the result.
  Future<String> toJwt() async {
    requireSecret(apiSecret);
    requireKey(apiKey);
    return JwtCodec.hs256(apiSecret).sign(claims);
  }

  /// Verifies [jwt]: its signature, its time claims, that it has an `exp`
  /// (as LiveKit's server SDKs require, `requiredClaims: ['exp']`) and
  /// that [apiKey] issued it; throws [JwtException] otherwise, and
  /// [StateError] without a secret or a key: HS256 over an empty key
  /// verifies whatever was signed with one, so a missing
  /// `LIVEKIT_API_SECRET` must not pass as a valid key, and an empty
  /// `LIVEKIT_API_KEY` would accept a token of any issuer that leaves `iss`
  /// out.
  static Future<LivekitClaims> verify(
    String jwt, {
    required String apiKey,
    required String apiSecret,
  }) async {
    requireSecret(apiSecret);
    requireKey(apiKey);
    return LivekitClaims(
      (await JwtCodec.hs256(
        apiSecret,
        issuer: apiKey,
        requiredClaims: const ['exp'],
      ).verify(jwt)).claims,
    );
  }

  /// [StateError] when [apiSecret] is empty.
  static void requireSecret(String apiSecret) {
    if (apiSecret.isEmpty) {
      throw StateError(
        'LIVEKIT_API_SECRET is not set: LiveKit tokens cannot be signed or '
        'verified without it.',
      );
    }
  }

  /// [StateError] when [apiKey] is empty or blank: it is the issuer of
  /// every token, and LiveKit refuses a token without one.
  static void requireKey(String apiKey) {
    if (apiKey.trim().isEmpty) {
      throw StateError(
        'LIVEKIT_API_KEY is not set: LiveKit tokens cannot be signed or '
        'verified without it.',
      );
    }
  }
}

/// The verified claims of a [LivekitToken].
final class LivekitClaims {
  /// The [claims] of a verified token.
  const LivekitClaims(this.claims);

  /// The raw claims.
  final Map<String, Object?> claims;

  /// The participant identity.
  String? get identity => _text('sub');

  /// The display name.
  String? get name => _text('name');

  /// The participant metadata.
  String? get metadata => _text('metadata');

  /// The SHA-256 of a webhook body.
  String? get sha256 => _text('sha256');

  /// The API key that issued it.
  String? get issuer => _text('iss');

  /// The video grant; [JwtException] when it is not an object.
  VideoGrant? get video => switch (claims['video']) {
    null => null,
    final Map<String, Object?> grant => VideoGrant.fromJson(grant),
    _ => throw const JwtException('The token video grant is not an object.'),
  };

  /// The text claim [name]; [JwtException] when it holds another type.
  String? _text(String name) => switch (claims[name]) {
    null => null,
    final String text => text,
    _ => throw JwtException('The token [$name] claim is not text.'),
  };

  /// The participant attributes.
  Map<String, String> get attributes => switch (claims['attributes']) {
    final Map<String, Object?> map => {
      for (final MapEntry(:key, :value) in map.entries) key: '$value',
    },
    _ => const {},
  };

  /// When the token expires.
  DateTime? get expiresAt => switch (claims['exp']) {
    final num seconds => DateTime.fromMillisecondsSinceEpoch(
      (seconds * 1000).round(),
      isUtc: true,
    ),
    _ => null,
  };
}
