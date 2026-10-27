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

  final String apiKey;
  final String apiSecret;

  /// The participant (`sub` and `jti`); required to join a room.
  final String? identity;

  /// The participant's display name.
  final String? name;

  /// Free-form text the other participants see (JSON, typically).
  final String? metadata;
  final Map<String, String>? attributes;

  /// How long the token is valid (4 hours, as LiveKit's SDKs).
  final Duration ttl;
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

  /// The signed JWT (HS256).
  Future<String> toJwt() => JwtCodec.hs256(apiSecret).sign(claims);

  /// Verifies [jwt]: its signature, its time claims and that [apiKey]
  /// issued it; throws [JwtException] otherwise.
  static Future<LivekitClaims> verify(
    String jwt, {
    required String apiKey,
    required String apiSecret,
  }) async => LivekitClaims(
    (await JwtCodec.hs256(apiSecret, issuer: apiKey).verify(jwt)).claims,
  );
}

/// The verified claims of a [LivekitToken].
final class LivekitClaims {
  const LivekitClaims(this.claims);

  final Map<String, Object?> claims;

  String? get identity => claims['sub'] as String?;
  String? get name => claims['name'] as String?;
  String? get metadata => claims['metadata'] as String?;
  String? get sha256 => claims['sha256'] as String?;
  String? get issuer => claims['iss'] as String?;

  VideoGrant? get video => switch (claims['video']) {
    final Map<String, Object?> grant => VideoGrant.fromJson(grant),
    _ => null,
  };

  Map<String, String> get attributes => switch (claims['attributes']) {
    final Map<String, Object?> map => {
      for (final MapEntry(:key, :value) in map.entries) key: '$value',
    },
    _ => const {},
  };

  DateTime? get expiresAt => switch (claims['exp']) {
    final num seconds => DateTime.fromMillisecondsSinceEpoch(
      (seconds * 1000).round(),
      isUtc: true,
    ),
    _ => null,
  };
}
