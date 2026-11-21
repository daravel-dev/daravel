import 'dart:convert';

import '../foundation/clock.dart';
import '../foundation/shared_result.dart';
import '../http/client.dart';
import 'jwt.dart';

/// A JSON Web Key Set (RFC 7517 §5): the signature keys in it that Daravel
/// verifies with, RSA ([RsaJwtKey], RS256) and OKP Ed25519
/// ([Ed25519JwtKey], EdDSA).
///
/// Keys Daravel has no use for are skipped, not an error, because a
/// provider's set may list them: encryption keys (`use: enc`, `key_ops`
/// without `verify`), other algorithms and curves, symmetric (`oct`) keys,
/// RSA keys under 2048 bits and malformed entries.
final class JsonWebKeySet {
  /// A set of [keys].
  JsonWebKeySet(List<JwtKey> keys) : keys = List<JwtKey>.unmodifiable(keys);

  /// The set in a JWKS document (`{"keys": [...]}`). Throws
  /// [FormatException] when [json] is not one.
  factory JsonWebKeySet.parse(String json) {
    final decoded = jsonDecode(json);
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('A JWKS document is a JSON object.');
    }
    return JsonWebKeySet.fromJson(decoded);
  }

  /// The set in a decoded JWKS document.
  factory JsonWebKeySet.fromJson(Map<String, Object?> json) {
    final entries = json['keys'];
    if (entries is! List<Object?>) {
      throw const FormatException('A JWKS document has a "keys" array.');
    }
    return JsonWebKeySet(<JwtKey>[
      for (final entry in entries)
        if (entry is Map<String, Object?>) ?_key(entry),
    ]);
  }

  /// The signature keys, in the document's order.
  final List<JwtKey> keys;

  /// The key whose `kid` is [kid], if any.
  JwtKey? byKid(String kid) {
    for (final key in keys) {
      if (key.kid == kid) {
        return key;
      }
    }
    return null;
  }

  static JwtKey? _key(Map<String, Object?> jwk) {
    final use = jwk['use'];
    final ops = jwk['key_ops'];
    if (use != null && use != 'sig') {
      return null;
    }
    if (ops != null && (ops is! List<Object?> || !ops.contains('verify'))) {
      return null;
    }
    final alg = jwk['alg'];
    try {
      switch (jwk['kty']) {
        case 'RSA' when alg == null || alg == 'RS256':
          return RsaJwtKey.fromJwk(jwk);
        case 'OKP'
            when jwk['crv'] == 'Ed25519' &&
                (alg == null || alg == 'EdDSA' || alg == 'Ed25519'):
          final x = jwk['x'];
          final kid = jwk['kid'];
          if (x is! String || (kid != null && kid is! String)) {
            return null;
          }
          final publicKey = base64Url.decode(base64Url.normalize(x));
          if (publicKey.length != 32) {
            return null;
          }
          return Ed25519JwtKey(publicKey: publicKey, kid: kid as String?);
        default:
          return null;
      }
    } on FormatException {
      return null;
    } on ArgumentError {
      return null;
    }
  }
}

/// Verifies JWTs signed by an identity provider with the keys it publishes
/// at [uri], a JWKS endpoint: Firebase Authentication and Google Sign-In
/// ([JwksVerifier.firebase], [JwksVerifier.google]), Auth0, Okta,
/// Keycloak, Cognito, Microsoft Entra ID... Like firebase/php-jwt's
/// `CachedKeySet` with `JWT::decode` in Laravel.
///
/// ```dart
/// final verifier = JwksVerifier.firebase('my-project');
/// final claims = await verifier.verify(idToken); // JwtException otherwise
/// final uid = claims.subject;
/// ```
///
/// The set is fetched on first use and kept for its response's
/// `Cache-Control: max-age` ([defaultCacheFor] without one), held between
/// [refetchInterval] and a day. A token whose `kid` is not in the set
/// fetches it again, since providers rotate keys, but at most once per
/// [refetchInterval], so tokens with made-up ids cannot turn every request
/// into a fetch. Concurrent verifications share one fetch, and when a
/// fetch fails the keys already held are kept.
///
/// Keep one verifier per provider (a container singleton): the set lives
/// in the instance, one copy per isolate.
final class JwksVerifier {
  /// A verifier for tokens signed with the keys at [uri]. [issuers], when
  /// not empty, holds the accepted `iss` values; [audience] is required in
  /// `aud`; [requiredClaims] must be present ([JwtCodec.requiredClaims]);
  /// [validate] may refuse a token with [JwtException] after every other
  /// check. [fetch] replaces the HTTP request (by default `Http`, with a
  /// 10-second timeout) and [clock] the time, both for tests.
  JwksVerifier(
    this.uri, {
    Set<String> issuers = const <String>{},
    this.audience,
    List<String> requiredClaims = const <String>['exp'],
    this.leeway = const Duration(seconds: 30),
    this.defaultCacheFor = const Duration(hours: 1),
    this.refetchInterval = const Duration(minutes: 1),
    this.validate,
    Future<ClientResponse> Function(Uri uri)? fetch,
    DateTime Function()? clock,
  }) : issuers = Set<String>.unmodifiable(issuers),
       requiredClaims = List<String>.unmodifiable(requiredClaims),
       _fetch = fetch ?? _httpGet,
       _clock = clock ?? _utcNow;

  /// Firebase Authentication ID tokens of [projectId], with the checks of
  /// the Admin SDK's `verifyIdToken`: Google's `securetoken` keys, `aud`
  /// the project, `iss` `https://securetoken.google.com/<projectId>`,
  /// `exp` and `iat` present, `sub` a non-empty string of at most 128
  /// characters and `auth_time` not in the future.
  factory JwksVerifier.firebase(
    String projectId, {
    Future<ClientResponse> Function(Uri uri)? fetch,
    DateTime Function()? clock,
  }) {
    final now = clock ?? _utcNow;
    return JwksVerifier(
      firebaseKeysUri,
      issuers: <String>{'https://securetoken.google.com/$projectId'},
      audience: projectId,
      requiredClaims: const <String>['exp', 'iat', 'sub', 'auth_time'],
      fetch: fetch,
      clock: clock,
      validate: (claims) {
        final sub = claims['sub'];
        if (sub is! String || sub.isEmpty || sub.length > 128) {
          throw const JwtException('Invalid subject.');
        }
        final authTime = claims['auth_time'];
        if (authTime is! num ||
            authTime * 1000 >
                now().add(const Duration(seconds: 30)).millisecondsSinceEpoch) {
          throw const JwtException('Invalid auth_time.');
        }
      },
    );
  }

  /// Google Sign-In ID tokens for the OAuth client [clientId]: Google's
  /// OAuth 2.0 keys, `aud` the client id, `iss` `https://accounts.google.com`
  /// or `accounts.google.com`, `exp`, `iat` and `sub` present.
  factory JwksVerifier.google(
    String clientId, {
    Future<ClientResponse> Function(Uri uri)? fetch,
    DateTime Function()? clock,
  }) => JwksVerifier(
    googleKeysUri,
    issuers: const <String>{
      'https://accounts.google.com',
      'accounts.google.com',
    },
    audience: clientId,
    requiredClaims: const <String>['exp', 'iat', 'sub'],
    fetch: fetch,
    clock: clock,
  );

  /// The keys that sign Firebase Authentication ID tokens.
  static final Uri firebaseKeysUri = Uri.https(
    'www.googleapis.com',
    '/service_accounts/v1/jwk/securetoken@system.gserviceaccount.com',
  );

  /// The keys that sign Google OAuth 2.0 / OpenID Connect ID tokens.
  static final Uri googleKeysUri = Uri.https(
    'www.googleapis.com',
    '/oauth2/v3/certs',
  );

  /// The JWKS endpoint.
  final Uri uri;

  /// Accepted `iss` values; empty accepts any.
  final Set<String> issuers;

  /// Required in `aud` when set.
  final String? audience;

  /// Claims a token must carry.
  final List<String> requiredClaims;

  /// Clock skew tolerated for `exp`, `nbf` and `iat`.
  final Duration leeway;

  /// How long a set is kept when its response has no `max-age`.
  final Duration defaultCacheFor;

  /// The shortest time between two fetches.
  final Duration refetchInterval;

  /// A last check of the verified claims; throws [JwtException] to refuse.
  final void Function(JwtClaims claims)? validate;

  final Future<ClientResponse> Function(Uri uri) _fetch;
  final DateTime Function() _clock;

  JsonWebKeySet? _set;
  DateTime? _expiresAt;
  DateTime? _fetchedAt;
  SharedResult<void>? _inFlight;

  /// The claims of [token] once its signature, times, issuer, audience and
  /// required claims are checked; throws [JwtException] otherwise, also when
  /// no key can be loaded.
  Future<JwtClaims> verify(String token) async {
    final header = JwtCodec.decodeUnverified(token).header;
    final kid = header['kid'];
    if (kid != null && kid is! String) {
      throw const JwtException('Malformed token.');
    }
    final keys = await _keysFor(kid as String?);
    if (keys.isEmpty) {
      throw const JwtException('No key matches the token.');
    }
    final claims = await JwtCodec(
      keys: keys,
      leeway: leeway,
      audience: audience,
      requiredClaims: requiredClaims,
      clock: _clock,
    ).verify(token);
    if (issuers.isNotEmpty && !issuers.contains(claims.issuer)) {
      throw const JwtException('Invalid issuer.');
    }
    validate?.call(claims);
    return claims;
  }

  /// Forgets the set, so the next verification fetches it.
  void flush() {
    _set = null;
    _expiresAt = null;
    _fetchedAt = null;
  }

  Future<List<JwtKey>> _keysFor(String? kid) async {
    final now = _clock();
    final expires = _expiresAt;
    if (_set == null || expires == null || !now.isBefore(expires)) {
      await _refresh(force: _set == null);
    } else if (kid != null && _set!.byKid(kid) == null) {
      await _refresh(force: false);
    }
    final set = _set;
    if (set == null) {
      throw JwtException('The signing keys at $uri could not be loaded.');
    }
    if (kid == null) {
      return set.keys;
    }
    final key = set.byKid(kid);
    return key == null ? const <JwtKey>[] : <JwtKey>[key];
  }

  Future<void> _refresh({required bool force}) async {
    final last = _fetchedAt;
    if (!force &&
        last != null &&
        _clock().isBefore(last.add(refetchInterval))) {
      return;
    }
    // One fetch for every caller, whatever zone (request) started it.
    final pending = _inFlight ??= SharedResult<void>(_load);
    try {
      await pending.value;
    } finally {
      if (identical(_inFlight, pending)) {
        _inFlight = null;
      }
    }
  }

  Future<void> _load() async {
    _fetchedAt = _clock();
    final ClientResponse response;
    try {
      response = await _fetch(uri);
    } on Object {
      return; // keep the keys held, if any
    }
    if (!response.successful) {
      return;
    }
    final JsonWebKeySet set;
    try {
      set = JsonWebKeySet.parse(response.body);
    } on FormatException {
      return;
    }
    _set = set;
    _expiresAt = _clock().add(_cacheFor(response.header('cache-control')));
  }

  Duration _cacheFor(String? cacheControl) {
    final match = RegExp(r'(?:^|[,\s])max-age=(\d+)')
        .firstMatch(cacheControl ?? '');
    final seconds = int.tryParse(match?.group(1) ?? '');
    final wanted = seconds == null
        ? defaultCacheFor
        : Duration(seconds: seconds);
    if (wanted < refetchInterval) {
      return refetchInterval;
    }
    return wanted > const Duration(days: 1) ? const Duration(days: 1) : wanted;
  }

  static Future<ClientResponse> _httpGet(Uri uri) =>
      Http.timeout(const Duration(seconds: 10))
          .acceptJson()
          .get(uri.toString());

  static DateTime _utcNow() => Clock.now().toUtc();
}
