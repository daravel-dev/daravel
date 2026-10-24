import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../foundation/clock.dart';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart' as cg;

import '../foundation/exceptions.dart';
import '../http/request.dart';
import 'contracts.dart';
import 'hashing.dart' show constantTimeBytesEquals;
import 'tokens.dart' show bearerTokenOf;

/// Signing algorithms (BLUEPRINT_V2 §7.6.2): HMAC-SHA256 and Ed25519.
enum JwtAlgorithm {
  hs256('HS256'),
  eddsa('EdDSA');

  const JwtAlgorithm(this.header);

  /// Value of the `alg` header.
  final String header;

  static JwtAlgorithm parse(String value) => values.firstWhere(
    (a) => a.header == value || a.name == value.toLowerCase(),
    orElse: () => throw ConfigException(
      'Unsupported JWT algorithm [$value]; use HS256 or EdDSA.',
    ),
  );
}

/// A signing/verification key with an optional `kid` for rotation.
sealed class JwtKey {
  const JwtKey({this.kid});

  final String? kid;

  JwtAlgorithm get algorithm;
}

/// Shared secret for HS256.
final class HmacJwtKey extends JwtKey {
  HmacJwtKey(List<int> secret, {super.kid})
    : secret = Uint8List.fromList(secret);

  /// Uses the UTF-8 bytes of [secret].
  factory HmacJwtKey.fromString(String secret, {String? kid}) =>
      HmacJwtKey(utf8.encode(secret), kid: kid);

  final Uint8List secret;

  @override
  JwtAlgorithm get algorithm => JwtAlgorithm.hs256;
}

/// Ed25519 key for EdDSA. Verification only needs [publicKey]; signing also
/// needs the 32-byte [seed].
final class Ed25519JwtKey extends JwtKey {
  const Ed25519JwtKey({required this.publicKey, this.seed, super.kid});

  final List<int> publicKey;
  final List<int>? seed;

  bool get canSign => seed != null;

  @override
  JwtAlgorithm get algorithm => JwtAlgorithm.eddsa;

  /// Generates a fresh key pair (`dartisan jwt:keygen`).
  static Future<Ed25519JwtKey> generate({String? kid}) async {
    final random = Random.secure();
    final seed = List<int>.generate(32, (_) => random.nextInt(256));
    final pair = await cg.Ed25519().newKeyPairFromSeed(seed);
    final public = await pair.extractPublicKey();
    return Ed25519JwtKey(publicKey: public.bytes, seed: seed, kid: kid);
  }
}

/// Raised for malformed, expired, not-yet-valid or badly signed tokens.
final class JwtException extends DaravelException {
  const JwtException(super.message);
}

/// Verified claims of a token.
final class JwtClaims {
  const JwtClaims(this.claims, {this.header = const <String, Object?>{}});

  final Map<String, Object?> claims;
  final Map<String, Object?> header;

  Object? operator [](String name) => claims[name];

  String? get subject => claims['sub']?.toString();
  String? get issuer => claims['iss'] as String?;
  Object? get audience => claims['aud'];
  String? get jti => claims['jti'] as String?;
  DateTime? get expiresAt => _time(claims['exp']);
  DateTime? get notBefore => _time(claims['nbf']);
  DateTime? get issuedAt => _time(claims['iat']);
  String? get kid => header['kid'] as String?;

  static DateTime? _time(Object? value) => value is num
      ? DateTime.fromMillisecondsSinceEpoch((value * 1000).round(), isUtc: true)
      : null;
}

/// Signs and verifies JWTs (RFC 7519) with a key ring.
///
/// The first key signs; verification picks the key by `kid` when present,
/// otherwise tries every key of the token's algorithm — which is what makes
/// rotation painless: add the new key first, keep the old one for a while.
final class JwtCodec {
  JwtCodec({
    required List<JwtKey> keys,
    this.leeway = const Duration(seconds: 30),
    this.issuer,
    this.audience,
    DateTime Function()? clock,
  }) : keys = List<JwtKey>.unmodifiable(keys),
       _clock = clock ?? _utcNow {
    if (keys.isEmpty) {
      throw const ConfigException('JwtCodec needs at least one key.');
    }
  }

  /// HS256 with one secret (`JWT_SECRET`).
  factory JwtCodec.hs256(
    String secret, {
    Duration leeway = const Duration(seconds: 30),
    String? issuer,
    String? audience,
  }) => JwtCodec(
    keys: <JwtKey>[HmacJwtKey.fromString(secret)],
    leeway: leeway,
    issuer: issuer,
    audience: audience,
  );

  final List<JwtKey> keys;

  /// Clock skew tolerated for `exp`/`nbf`/`iat`.
  final Duration leeway;

  /// When set, `iss` is added on sign and required on verify.
  final String? issuer;

  /// When set, `aud` is added on sign and required on verify.
  final String? audience;

  final DateTime Function() _clock;

  /// Signs [claims]. Missing `iat` is filled in; `iss`/`aud` are added from
  /// the codec configuration when absent.
  Future<String> sign(Map<String, Object?> claims, {JwtKey? key}) async {
    final signingKey = key ?? keys.first;
    final header = <String, Object?>{
      'alg': signingKey.algorithm.header,
      'typ': 'JWT',
      if (signingKey.kid != null) 'kid': signingKey.kid,
    };
    final payload = <String, Object?>{
      if (issuer != null) 'iss': issuer,
      if (audience != null) 'aud': audience,
      'iat': _clock().millisecondsSinceEpoch ~/ 1000,
      ...claims,
    };
    final input =
        '${_encode(utf8.encode(jsonEncode(header)))}.'
        '${_encode(utf8.encode(jsonEncode(payload)))}';
    final signature = await _sign(signingKey, utf8.encode(input));
    return '$input.${_encode(signature)}';
  }

  /// Verifies signature and time claims; throws [JwtException] otherwise.
  Future<JwtClaims> verify(String token) async {
    final parts = token.split('.');
    if (parts.length != 3) {
      throw const JwtException('Malformed token.');
    }
    final Map<String, Object?> header;
    final Map<String, Object?> payload;
    final List<int> signature;
    try {
      header = _json(parts[0]);
      payload = _json(parts[1]);
      signature = _decode(parts[2]);
    } on FormatException {
      throw const JwtException('Malformed token.');
    }
    final alg = header['alg'];
    if (alg is! String || alg == 'none') {
      throw const JwtException('Unsupported or missing alg header.');
    }
    final JwtAlgorithm algorithm;
    try {
      algorithm = JwtAlgorithm.parse(alg);
    } on ConfigException {
      throw JwtException('Unsupported algorithm [$alg].');
    }
    final kid = header['kid'] as String?;
    final candidates = keys.where(
      (k) => k.algorithm == algorithm && (kid == null || k.kid == kid),
    );
    if (candidates.isEmpty) {
      throw const JwtException('No key matches the token.');
    }
    final input = utf8.encode('${parts[0]}.${parts[1]}');
    var valid = false;
    for (final key in candidates) {
      if (await _verify(key, input, signature)) {
        valid = true;
        break;
      }
    }
    if (!valid) {
      throw const JwtException('Invalid signature.');
    }
    _checkTimeClaims(payload);
    if (issuer != null && payload['iss'] != issuer) {
      throw const JwtException('Invalid issuer.');
    }
    if (audience != null) {
      final aud = payload['aud'];
      final ok = aud is List<Object?>
          ? aud.contains(audience)
          : aud == audience;
      if (!ok) {
        throw const JwtException('Invalid audience.');
      }
    }
    return JwtClaims(payload, header: header);
  }

  /// Decodes header and payload without verifying anything.
  static ({Map<String, Object?> header, Map<String, Object?> payload})
  decodeUnverified(String token) {
    final parts = token.split('.');
    if (parts.length != 3) {
      throw const JwtException('Malformed token.');
    }
    try {
      return (header: _json(parts[0]), payload: _json(parts[1]));
    } on FormatException {
      throw const JwtException('Malformed token.');
    }
  }

  void _checkTimeClaims(Map<String, Object?> payload) {
    final now = _clock().millisecondsSinceEpoch / 1000;
    final skew = leeway.inMilliseconds / 1000;
    final exp = payload['exp'];
    if (exp is num && now - skew >= exp) {
      throw const JwtException('Token has expired.');
    }
    final nbf = payload['nbf'];
    if (nbf is num && now + skew < nbf) {
      throw const JwtException('Token is not yet valid.');
    }
    final iat = payload['iat'];
    if (iat is num && now + skew < iat) {
      throw const JwtException('Token was issued in the future.');
    }
  }

  Future<List<int>> _sign(JwtKey key, List<int> input) async {
    switch (key) {
      case HmacJwtKey():
        return crypto.Hmac(crypto.sha256, key.secret).convert(input).bytes;
      case Ed25519JwtKey():
        final seed = key.seed;
        if (seed == null) {
          throw const ConfigException(
            'This Ed25519 key has no private seed and cannot sign.',
          );
        }
        final pair = await cg.Ed25519().newKeyPairFromSeed(seed);
        return (await cg.Ed25519().sign(input, keyPair: pair)).bytes;
    }
  }

  Future<bool> _verify(JwtKey key, List<int> input, List<int> signature) {
    switch (key) {
      case HmacJwtKey():
        final expected = crypto.Hmac(
          crypto.sha256,
          key.secret,
        ).convert(input).bytes;
        return Future<bool>.value(constantTimeBytesEquals(expected, signature));
      case Ed25519JwtKey():
        if (signature.length != 64) {
          return Future<bool>.value(false);
        }
        return cg.Ed25519().verify(
          input,
          signature: cg.Signature(
            signature,
            publicKey: cg.SimplePublicKey(
              key.publicKey,
              type: cg.KeyPairType.ed25519,
            ),
          ),
        );
    }
  }

  static Map<String, Object?> _json(String segment) {
    final decoded = jsonDecode(utf8.decode(_decode(segment)));
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('JWT segment is not a JSON object.');
    }
    return decoded;
  }

  static String _encode(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static List<int> _decode(String segment) =>
      base64Url.decode(segment.padRight((segment.length + 3) ~/ 4 * 4, '='));

  static DateTime _utcNow() => Clock.now().toUtc();
}

/// Revoked token ids (`jti`) until their expiry.
abstract interface class JwtDenylist {
  Future<void> add(String jti, DateTime expiresAt);

  Future<bool> contains(String jti);
}

/// In-memory denylist (per isolate). A cache-backed store arrives with S9.
final class MemoryJwtDenylist implements JwtDenylist {
  MemoryJwtDenylist({DateTime Function()? clock}) : _clock = clock ?? _utcNow;

  final Map<String, DateTime> _entries = <String, DateTime>{};
  final DateTime Function() _clock;

  @override
  Future<void> add(String jti, DateTime expiresAt) async {
    _prune();
    _entries[jti] = expiresAt;
  }

  @override
  Future<bool> contains(String jti) async {
    _prune();
    return _entries.containsKey(jti);
  }

  void _prune() {
    final now = _clock();
    _entries.removeWhere((_, exp) => !exp.isAfter(now));
  }

  static DateTime _utcNow() => Clock.now().toUtc();
}

/// Stateless bearer-JWT guard: `sub` is the user's identifier.
final class JwtGuard<T extends Authenticatable> extends RequestGuard<T> {
  JwtGuard({
    required super.name,
    required UserProvider<T> provider,
    required this.codec,
    this.ttl = const Duration(minutes: 60),
    this.denylist,
    DateTime Function()? clock,
  }) : _clock = clock ?? _utcNow,
       super(provider: provider);

  final JwtCodec codec;

  /// Default lifetime of issued tokens.
  final Duration ttl;

  /// Optional revocation list checked on every request.
  final JwtDenylist? denylist;

  final DateTime Function() _clock;

  UserProvider<T> get users => provider!;

  @override
  Future<T?> resolveUser(Request request) async {
    final bearer = bearerTokenOf(request);
    if (bearer == null || bearer.isEmpty) {
      return null;
    }
    final JwtClaims claims;
    try {
      claims = await codec.verify(bearer);
    } on JwtException {
      return null;
    }
    final jti = claims.jti;
    if (jti != null && await (denylist?.contains(jti) ?? Future.value(false))) {
      return null;
    }
    final sub = claims.subject;
    if (sub == null) {
      return null;
    }
    final user = await users.retrieveById(int.tryParse(sub) ?? sub);
    if (user == null) {
      return null;
    }
    AuthScope.state().token = claims;
    return user;
  }

  /// Issues a signed token for [user] with `sub`, `iat`, `exp`, `jti`.
  Future<String> issue(
    Authenticatable user, {
    Duration? ttl,
    Map<String, Object?> claims = const <String, Object?>{},
  }) {
    final now = _clock();
    final expires = now.add(ttl ?? this.ttl);
    return codec.sign(<String, Object?>{
      'sub': user.authIdentifier.toString(),
      'iat': now.millisecondsSinceEpoch ~/ 1000,
      'exp': expires.millisecondsSinceEpoch ~/ 1000,
      'jti': _jti(),
      ...claims,
    });
  }

  /// Claims of the token authenticating the current request.
  Future<JwtClaims?> claims() async {
    await user();
    return AuthScope.state().token as JwtClaims?;
  }

  /// Revokes [token] (defaults to the current request's token) via the
  /// denylist until it expires. Throws [StateError] without a denylist.
  Future<void> invalidate([String? token]) async {
    final list = denylist;
    if (list == null) {
      throw StateError(
        'JwtGuard [$name] has no denylist; pass denylist: MemoryJwtDenylist() '
        'to support invalidation.',
      );
    }
    final JwtClaims? current = token == null
        ? await claims()
        : JwtClaims(JwtCodec.decodeUnverified(token).payload);
    final jti = current?.jti;
    if (jti == null) {
      return;
    }
    await list.add(
      jti,
      current!.expiresAt ?? _clock().add(const Duration(days: 365)),
    );
    if (token == null) {
      forgetUser();
    }
  }

  static String _jti() {
    final random = Random.secure();
    return base64Url
        .encode(List<int>.generate(16, (_) => random.nextInt(256)))
        .replaceAll('=', '');
  }

  static DateTime _utcNow() => Clock.now().toUtc();
}
