import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

// RFC 7515 Appendix A.2: the RS256 example key (n, e, d) and its JWS.
const _rfcN =
    'ofgWCuLjybRlzo0tZWJjNiuSfb4p4fAkd_wWJcyQoTbji9k0l8W26mPddx'
    'HmfHQp-Vaw-4qPCJrcS2mJPMEzP1Pt0Bm4d4QlL-yRT-SFd2lZS-pCgNMs'
    'D1W_YpRPEwOWvG6b32690r2jZ47soMZo9wGzjb_7OMg0LOL-bSf63kpaSH'
    'SXndS5z5rexMdbBYUsLA9e-KXBdQOS-UTo7WTBEMa2R2CapHg665xsmtdV'
    'MTBQY4uDZlxvb3qCo5ZwKh9kG4LT6_I5IhlJH7aGhyxXFvUK-DWNmoudF8'
    'NAco9_h9iaGNj8q2ethFkMLs91kzk2PAcDTW9gb54h4FRWyuXpoQ';
const _rfcD =
    'Eq5xpGnNCivDflJsRQBXHx1hdR1k6Ulwe2JZD50LpXyWPEAeP88vLNO97I'
    'jlA7_GQ5sLKMgvfTeXZx9SE-7YwVol2NXOoAJe46sui395IW_GO-pWJ1O0'
    'BkTGoVEn2bKVRUCgu-GjBVaYLU6f3l9kJfFNS3E0QbVdxzubSu3Mkqzjkn'
    '439X0M_V51gfpRLI9JYanrC4D4qAdGcopV_0ZHHzQlBjudU2QvXt4ehNYT'
    'CBr6XCLQUShb1juUO1ZdiYoFaFQT5Tw8bGUl_x_jTj3ccPDVZFD9pIuhLh'
    'BOneufuBiB4cS98l2SR_RQyGWSeWjnczT0QU91p1DhOVRuOopznQ';
const _rfcToken =
    'eyJhbGciOiJSUzI1NiJ9'
    '.'
    'eyJpc3MiOiJqb2UiLA0KICJleHAiOjEzMDA4MTkzODAsDQogImh0dHA6Ly9leGFt'
    'cGxlLmNvbS9pc19yb290Ijp0cnVlfQ'
    '.'
    'cC4hiUPoj9Eetdgtv3hF80EGrhuB__dzERat0XF9g2VtQgr9PJbu3XOiZj5RZmh7'
    'AAuHIm4Bh-0Qc_lF5YKt_O8W2Fp5jujGbds9uJdbF9CUAr7t1dnZcAcQjbKBYNX4'
    'BAynRFdiuB--f_nZLgrnbyTyWzO75vRK5h6xBArLIARNPvkSjtQBMHlb1L07Qe7K'
    '0GarZRmB_eSN9383LcOLn6_dO--xi12jzDwusC-eOkHWEsqtFZESc6BfI7noOPqv'
    'hJ1phCnvWh6IeYI2w9QOYEUipUTI8np6LbgGY9Fs98rqVt5AXLIhWkWywlVmtVrB'
    'p0igcN_IoypGlUPQGe77Rw';

// RFC 8037 Appendix A.1/A.2: the Ed25519 example key.
const _edD = 'nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A';
const _edX = '11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo';

List<int> _b64(String s) => base64Url.decode(base64Url.normalize(s));
String _enc(List<int> b) => base64Url.encode(b).replaceAll('=', '');

BigInt _int(List<int> bytes) =>
    bytes.fold(BigInt.zero, (v, b) => (v << 8) | BigInt.from(b));

final BigInt _n = _int(_b64(_rfcN));
final BigInt _d = _int(_b64(_rfcD));

Map<String, Object?> _rfcJwk({String? kid, Map<String, Object?>? extra}) => {
  'kty': 'RSA',
  'n': _rfcN,
  'e': 'AQAB',
  'kid': ?kid,
  ...?extra,
};

/// RSASSA-PKCS1-v1_5 SHA-256 signing with the RFC's private exponent,
/// written out independently of the verifier (test only).
List<int> _rsaSign(String input, {BigInt? d}) {
  const prefix = <int>[
    0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01, //
    0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20,
  ];
  final t = [...prefix, ...crypto.sha256.convert(utf8.encode(input)).bytes];
  final k = (_n.bitLength + 7) ~/ 8;
  final em = [
    0x00,
    0x01,
    ...List<int>.filled(k - t.length - 3, 0xff),
    0x00,
    ...t,
  ];
  var s = _int(em).modPow(d ?? _d, _n);
  final out = Uint8List(k);
  for (var i = k - 1; i >= 0; i--) {
    out[i] = (s & BigInt.from(0xff)).toInt();
    s >>= 8;
  }
  return out;
}

String _rs256(Map<String, Object?> payload, {String? kid}) {
  final header = _enc(
    utf8.encode(jsonEncode({'alg': 'RS256', 'typ': 'JWT', 'kid': ?kid})),
  );
  final body = _enc(utf8.encode(jsonEncode(payload)));
  return '$header.$body.${_enc(_rsaSign('$header.$body'))}';
}

void main() {
  final fixed = DateTime.utc(2026, 11, 21, 6);
  var now = fixed;
  DateTime clock() => now;
  int at(Duration offset) => fixed.add(offset).millisecondsSinceEpoch ~/ 1000;

  setUp(() => now = fixed);

  group('RS256', () {
    test('verifies the RFC 7515 A.2 example JWS', () async {
      final codec = JwtCodec(
        keys: [RsaJwtKey.fromJwk(_rfcJwk())],
        clock: clock,
      );
      // Its exp is in 2011; the signature is what is checked here.
      final claims = await codec.verify(_rfcToken, checkTimes: false);
      expect(claims.issuer, 'joe');
      expect(claims['http://example.com/is_root'], isTrue);
      await expectLater(codec.verify(_rfcToken), throwsA(isA<JwtException>()));
    });

    test('the encoding matches the RFC signature byte for byte', () {
      final parts = _rfcToken.split('.');
      expect(_rsaSign('${parts[0]}.${parts[1]}'), _b64(parts[2]));
    });

    test('refuses changed payloads, signatures and lengths', () async {
      final codec = JwtCodec(
        keys: [RsaJwtKey.fromJwk(_rfcJwk())],
        clock: clock,
      );
      final parts = _rfcToken.split('.');
      final otherPayload = _enc(utf8.encode('{"iss":"mallory","exp":1}'));
      final sig = _b64(parts[2]);
      final flipped = [...sig]..[sig.length - 1] ^= 1;
      final k = (_n.bitLength + 7) ~/ 8;
      final tooBig = List<int>.filled(k, 0xff); // >= n
      for (final token in [
        '${parts[0]}.$otherPayload.${parts[2]}',
        '${parts[0]}.${parts[1]}.${_enc(flipped)}',
        '${parts[0]}.${parts[1]}.${_enc(sig.sublist(1))}',
        '${parts[0]}.${parts[1]}.${_enc([0, ...sig])}',
        '${parts[0]}.${parts[1]}.${_enc(tooBig)}',
        '${parts[0]}.${parts[1]}.',
      ]) {
        await expectLater(
          codec.verify(token, checkTimes: false),
          throwsA(isA<JwtException>()),
          reason: token,
        );
      }
    });

    test('a token signed with another key is refused', () async {
      // Same modulus, wrong private exponent: a valid-looking signature.
      final header = _enc(utf8.encode('{"alg":"RS256"}'));
      final body = _enc(utf8.encode('{"sub":"1"}'));
      final forged = _enc(_rsaSign('$header.$body', d: _d - BigInt.two));
      await expectLater(
        JwtCodec(
          keys: [RsaJwtKey.fromJwk(_rfcJwk())],
          clock: clock,
        ).verify('$header.$body.$forged'),
        throwsA(
          isA<JwtException>().having(
            (e) => e.message,
            'message',
            'Invalid signature.',
          ),
        ),
      );
    });

    test('no algorithm confusion: HS256 over the RSA public key', () async {
      // The classic attack: sign HS256 with the public key as the secret.
      final secret = _b64(_rfcN);
      final header = _enc(utf8.encode('{"alg":"HS256"}'));
      final body = _enc(utf8.encode('{"sub":"admin"}'));
      final mac = crypto.Hmac(
        crypto.sha256,
        secret,
      ).convert(utf8.encode('$header.$body')).bytes;
      await expectLater(
        JwtCodec(
          keys: [RsaJwtKey.fromJwk(_rfcJwk())],
          clock: clock,
        ).verify('$header.$body.${_enc(mac)}'),
        throwsA(
          isA<JwtException>().having(
            (e) => e.message,
            'message',
            'No key matches the token.',
          ),
        ),
      );
    });

    test('keys are checked and only verify', () async {
      expect(
        () => RsaJwtKey(
          modulus: (BigInt.one << 1023) | BigInt.one,
          exponent: BigInt.from(65537),
        ),
        throwsArgumentError,
      );
      expect(
        () => RsaJwtKey(modulus: _n, exponent: BigInt.from(65536)),
        throwsArgumentError,
      );
      expect(
        () => RsaJwtKey(modulus: _n, exponent: BigInt.one),
        throwsArgumentError,
      );
      expect(
        () => RsaJwtKey.fromJwk({'kty': 'EC', 'x': 'a', 'y': 'b'}),
        throwsFormatException,
      );
      final key = RsaJwtKey.fromJwk(_rfcJwk(kid: 'k1'));
      expect(key.kid, 'k1');
      expect(key.length, 256);
      expect(key.algorithm.header, 'RS256');
      await expectLater(
        JwtCodec(keys: [key]).sign({'sub': '1'}),
        throwsA(isA<ConfigException>()),
      );
      expect(JwtAlgorithm.parse('RS256'), JwtAlgorithm.rs256);
    });

    test('JWT_ALGO=RS256 is refused for the guard', () {
      expect(
        () => AuthManager(
          const AuthConfig(jwtAlgorithm: JwtAlgorithm.rs256),
          appKey: 'base64:${base64.encode(List<int>.filled(32, 7))}',
        ).defaultJwtCodec(),
        throwsA(
          isA<ConfigException>().having(
            (e) => e.message,
            'message',
            contains('JwksVerifier'),
          ),
        ),
      );
    });
  });

  group('JsonWebKeySet', () {
    test('reads RSA and Ed25519 signature keys, skips the rest', () {
      final set = JsonWebKeySet.parse(
        jsonEncode({
          'keys': [
            _rfcJwk(kid: 'rsa', extra: {'alg': 'RS256', 'use': 'sig'}),
            {'kty': 'OKP', 'crv': 'Ed25519', 'x': _edX, 'kid': 'ed'},
            _rfcJwk(kid: 'enc', extra: {'use': 'enc'}),
            _rfcJwk(
              kid: 'ops',
              extra: {
                'key_ops': ['encrypt'],
              },
            ),
            _rfcJwk(kid: 'ps256', extra: {'alg': 'PS256'}),
            {'kty': 'oct', 'k': 'c2VjcmV0', 'kid': 'hmac'},
            {'kty': 'EC', 'crv': 'P-256', 'x': 'a', 'y': 'b', 'kid': 'ec'},
            {'kty': 'OKP', 'crv': 'X25519', 'x': _edX, 'kid': 'x25519'},
            {'kty': 'OKP', 'crv': 'Ed25519', 'x': 'AAAA', 'kid': 'short'},
            {'kty': 'RSA', 'n': 'AQAB', 'e': 'AQAB', 'kid': 'tiny'},
            {'kty': 'RSA', 'n': '!!!', 'e': 'AQAB', 'kid': 'garbage'},
            {'kty': 'RSA', 'n': _rfcN, 'e': 'AQAB', 'kid': 7},
            'not a map',
          ],
        }),
      );
      expect(set.keys.map((k) => k.kid), ['rsa', 'ed']);
      expect(set.byKid('rsa'), isA<RsaJwtKey>());
      final ed = set.byKid('ed')! as Ed25519JwtKey;
      expect(ed.publicKey, _b64(_edX));
      expect(ed.canSign, isFalse);
      expect(set.byKid('enc'), isNull);
    });

    test('refuses documents that are not key sets', () {
      expect(() => JsonWebKeySet.parse('[]'), throwsFormatException);
      expect(() => JsonWebKeySet.parse('{"keys": 1}'), throwsFormatException);
      expect(() => JsonWebKeySet.parse('nope'), throwsFormatException);
    });

    test('an RFC 8037 Ed25519 key from a set verifies its tokens', () async {
      final signer = JwtCodec(
        keys: [
          Ed25519JwtKey(publicKey: _b64(_edX), seed: _b64(_edD), kid: 'ed'),
        ],
        clock: clock,
      );
      final token = await signer.sign({'sub': '7'});
      final set = JsonWebKeySet.fromJson({
        'keys': [
          {'kty': 'OKP', 'crv': 'Ed25519', 'x': _edX, 'kid': 'ed'},
        ],
      });
      final claims = await JwtCodec(keys: set.keys, clock: clock).verify(token);
      expect(claims.subject, '7');
    });
  });

  group('JwksVerifier', () {
    late List<Uri> fetched;
    late List<Map<String, Object?>> served;
    var cacheControl = 'public, max-age=3600';
    Object? failWith;

    Future<ClientResponse> fetch(Uri uri) async {
      fetched.add(uri);
      final error = failWith;
      if (error != null) {
        throw error;
      }
      return ClientResponse.fake(
        {'keys': served},
        headers: {'cache-control': cacheControl},
      );
    }

    setUp(() {
      fetched = <Uri>[];
      served = [_rfcJwk(kid: 'k1')];
      cacheControl = 'public, max-age=3600';
      failWith = null;
    });

    Map<String, Object?> claims([Map<String, Object?> extra = const {}]) => {
      'iss': 'https://issuer.example',
      'aud': 'my-app',
      'sub': 'user-1',
      'iat': at(Duration.zero),
      'exp': at(const Duration(hours: 1)),
      ...extra,
    };

    JwksVerifier verifier() => JwksVerifier(
      Uri.parse('https://issuer.example/jwks'),
      issuers: {'https://issuer.example'},
      audience: 'my-app',
      fetch: fetch,
      clock: clock,
    );

    test('verifies with the fetched keys and caches them', () async {
      final v = verifier();
      expect((await v.verify(_rs256(claims(), kid: 'k1'))).subject, 'user-1');
      expect((await v.verify(_rs256(claims()))).subject, 'user-1'); // no kid
      expect(fetched, [Uri.parse('https://issuer.example/jwks')]);
    });

    test('refetches after max-age', () async {
      cacheControl = 'max-age=600';
      final v = verifier();
      await v.verify(_rs256(claims(), kid: 'k1'));
      now = fixed.add(const Duration(minutes: 9));
      await v.verify(_rs256(claims(), kid: 'k1'));
      expect(fetched, hasLength(1));
      now = fixed.add(const Duration(minutes: 11));
      await v.verify(_rs256(claims(), kid: 'k1'));
      expect(fetched, hasLength(2));
    });

    test('an unknown kid refetches, at most once per interval', () async {
      final v = verifier();
      await v.verify(_rs256(claims(), kid: 'k1'));
      // Rotation: the provider now signs with k2.
      served = [_rfcJwk(kid: 'k2')];
      now = fixed.add(const Duration(minutes: 2));
      expect((await v.verify(_rs256(claims(), kid: 'k2'))).subject, 'user-1');
      expect(fetched, hasLength(2));
      // Made-up kids within the interval do not fetch again.
      for (final kid in ['x', 'y', 'z']) {
        await expectLater(
          v.verify(_rs256(claims(), kid: kid)),
          throwsA(isA<JwtException>()),
        );
      }
      expect(fetched, hasLength(2));
    });

    test('concurrent verifications share one fetch', () async {
      final v = verifier();
      final results = await Future.wait([
        for (var i = 0; i < 8; i++) v.verify(_rs256(claims(), kid: 'k1')),
      ]);
      expect(results, hasLength(8));
      expect(fetched, hasLength(1));
    });

    test(
      'a failed fetch keeps the keys held; none held is a JwtException',
      () async {
        final v = verifier();
        await v.verify(_rs256(claims(), kid: 'k1'));
        failWith = const SocketExceptionLike();
        now = fixed.add(const Duration(hours: 2));
        // Expired cache, fetch fails: the old keys still verify.
        final late = _rs256({
          ...claims(),
          'iat': at(const Duration(hours: 2)),
          'exp': at(const Duration(hours: 3)),
        }, kid: 'k1');
        expect((await v.verify(late)).subject, 'user-1');

        final cold = verifier();
        await expectLater(
          cold.verify(_rs256(claims(), kid: 'k1')),
          throwsA(
            isA<JwtException>().having(
              (e) => e.message,
              'message',
              contains('could not be loaded'),
            ),
          ),
        );
      },
    );

    test('issuer, audience, time and required claims are checked', () async {
      final v = verifier();
      for (final bad in [
        claims({'iss': 'https://evil.example'}),
        claims({'aud': 'other-app'}),
        claims({'exp': at(const Duration(minutes: -5))}),
        {...claims()}..remove('exp'),
      ]) {
        await expectLater(
          v.verify(_rs256(bad, kid: 'k1')),
          throwsA(isA<JwtException>()),
          reason: '$bad',
        );
      }
    });

    test('JwksVerifier.firebase applies the Admin SDK checks', () async {
      Map<String, Object?> firebase([Map<String, Object?> extra = const {}]) =>
          {
            'iss': 'https://securetoken.google.com/uji-nusa',
            'aud': 'uji-nusa',
            'sub': 'firebase-uid',
            'auth_time': at(const Duration(minutes: -1)),
            'iat': at(Duration.zero),
            'exp': at(const Duration(hours: 1)),
            ...extra,
          };
      final v = JwksVerifier.firebase('uji-nusa', fetch: fetch, clock: clock);
      expect(v.uri, JwksVerifier.firebaseKeysUri);
      expect(
        (await v.verify(_rs256(firebase(), kid: 'k1'))).subject,
        'firebase-uid',
      );
      for (final bad in [
        firebase({'aud': 'other-project'}),
        firebase({'iss': 'https://securetoken.google.com/other-project'}),
        firebase({'sub': ''}),
        firebase({'sub': 'x' * 129}),
        firebase({'auth_time': at(const Duration(hours: 1))}),
        {...firebase()}..remove('auth_time'),
      ]) {
        await expectLater(
          v.verify(_rs256(bad, kid: 'k1')),
          throwsA(isA<JwtException>()),
          reason: '$bad',
        );
      }
      expect(fetched.single, JwksVerifier.firebaseKeysUri);
    });

    test('JwksVerifier.google accepts both Google issuers', () async {
      final v = JwksVerifier.google(
        'client.apps.googleusercontent.com',
        fetch: fetch,
        clock: clock,
      );
      for (final iss in [
        'https://accounts.google.com',
        'accounts.google.com',
      ]) {
        final token = _rs256({
          'iss': iss,
          'aud': 'client.apps.googleusercontent.com',
          'sub': '1099',
          'iat': at(Duration.zero),
          'exp': at(const Duration(hours: 1)),
        }, kid: 'k1');
        expect((await v.verify(token)).subject, '1099');
      }
      expect(fetched.single, JwksVerifier.googleKeysUri);
    });
  });
}

/// A network failure stand-in (no socket in a unit test).
final class SocketExceptionLike implements Exception {
  const SocketExceptionLike();
}
