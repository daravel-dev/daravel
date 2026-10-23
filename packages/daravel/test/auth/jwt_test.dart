import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  final fixed = DateTime.utc(2026, 10, 24, 12);
  var now = fixed;
  DateTime clock() => now;

  setUp(() => now = fixed);

  JwtCodec hs256({String? issuer, String? audience}) => JwtCodec(
    keys: [HmacJwtKey.fromString('a-very-long-secret-of-at-least-32-bytes!')],
    clock: clock,
    issuer: issuer,
    audience: audience,
  );

  test('verifies the RFC 7519 / jwt.io HS256 reference token', () async {
    const token =
        'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.'
        'eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.'
        'SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c';
    final codec = JwtCodec(
      keys: [HmacJwtKey.fromString('your-256-bit-secret')],
      clock: clock,
    );
    final claims = await codec.verify(token);
    expect(claims.subject, '1234567890');
    expect(claims['name'], 'John Doe');
    expect(claims.issuedAt, DateTime.utc(2018, 1, 18, 1, 30, 22));
    expect(claims.header['alg'], 'HS256');
    final wrongSecret = JwtCodec(
      keys: [HmacJwtKey.fromString('another-secret')],
      clock: clock,
    );
    expect(() => wrongSecret.verify(token), throwsA(isA<JwtException>()));
  });

  test('sign → verify round trip adds iat and keeps custom claims', () async {
    final codec = hs256(issuer: 'daravel', audience: 'api');
    final token = await codec.sign({'sub': '42', 'role': 'admin'});
    expect(token.split('.'), hasLength(3));
    final claims = await codec.verify(token);
    expect(claims.subject, '42');
    expect(claims['role'], 'admin');
    expect(claims.issuer, 'daravel');
    expect(claims.audience, 'api');
    expect(claims.issuedAt, fixed);
    final decoded = JwtCodec.decodeUnverified(token);
    expect(decoded.payload['sub'], '42');
  });

  test('time claims: exp, nbf, iat with leeway', () async {
    final codec = hs256();
    final exp =
        fixed.add(const Duration(minutes: 5)).millisecondsSinceEpoch ~/ 1000;
    final token = await codec.sign({'sub': '1', 'exp': exp});
    now = fixed.add(const Duration(minutes: 5, seconds: 10));
    // 10 s past expiry is within the 30 s leeway.
    expect((await codec.verify(token)).subject, '1');
    now = fixed.add(const Duration(minutes: 6));
    await expectLater(
      () => codec.verify(token),
      throwsA(
        predicate((e) => e is JwtException && e.message.contains('expired')),
      ),
    );

    now = fixed;
    final nbf =
        fixed.add(const Duration(minutes: 2)).millisecondsSinceEpoch ~/ 1000;
    final early = await codec.sign({'sub': '1', 'nbf': nbf});
    await expectLater(
      () => codec.verify(early),
      throwsA(
        predicate((e) => e is JwtException && e.message.contains('not yet')),
      ),
    );
    now = fixed.add(const Duration(minutes: 2));
    expect((await codec.verify(early)).subject, '1');
  });

  test(
    'issuer/audience mismatches, tampering and alg=none are rejected',
    () async {
      final codec = hs256(issuer: 'daravel', audience: 'api');
      final foreign = await hs256(
        issuer: 'other',
        audience: 'api',
      ).sign({'sub': '1'});
      expect(() => codec.verify(foreign), throwsA(isA<JwtException>()));
      final wrongAud = await hs256(
        issuer: 'daravel',
        audience: 'web',
      ).sign({'sub': '1'});
      expect(() => codec.verify(wrongAud), throwsA(isA<JwtException>()));

      final token = await codec.sign({'sub': '1'});
      final parts = token.split('.');
      final tampered = '${parts[0]}.${parts[1]}x.${parts[2]}';
      expect(() => codec.verify(tampered), throwsA(isA<JwtException>()));
      expect(() => codec.verify('abc'), throwsA(isA<JwtException>()));
      // alg: none
      const noneHeader = 'eyJhbGciOiJub25lIiwidHlwIjoiSldUIn0';
      expect(
        () => codec.verify('$noneHeader.${parts[1]}.'),
        throwsA(isA<JwtException>()),
      );
    },
  );

  test(
    'key rotation with kid: new key signs, old key still verifies',
    () async {
      final oldKey = HmacJwtKey.fromString(
        'old-secret-old-secret-old-secret-old!',
        kid: 'v1',
      );
      final newKey = HmacJwtKey.fromString(
        'new-secret-new-secret-new-secret-new!',
        kid: 'v2',
      );
      final before = JwtCodec(keys: [oldKey], clock: clock);
      final issued = await before.sign({'sub': '9'});
      final rotated = JwtCodec(keys: [newKey, oldKey], clock: clock);
      expect((await rotated.verify(issued)).kid, 'v1');
      final fresh = await rotated.sign({'sub': '9'});
      expect(JwtCodec.decodeUnverified(fresh).header['kid'], 'v2');
      expect(() => before.verify(fresh), throwsA(isA<JwtException>()));
    },
  );

  test('EdDSA (Ed25519) sign/verify; verify-only keys cannot sign', () async {
    final key = await Ed25519JwtKey.generate(kid: 'ed1');
    final signer = JwtCodec(keys: [key], clock: clock);
    final token = await signer.sign({'sub': '7'});
    expect(JwtCodec.decodeUnverified(token).header['alg'], 'EdDSA');
    final verifier = JwtCodec(
      keys: [Ed25519JwtKey(publicKey: key.publicKey, kid: 'ed1')],
      clock: clock,
    );
    expect((await verifier.verify(token)).subject, '7');
    expect(() => verifier.sign({'sub': '1'}), throwsA(isA<ConfigException>()));
    final otherKey = await Ed25519JwtKey.generate();
    expect(
      () => JwtCodec(keys: [otherKey], clock: clock).verify(token),
      throwsA(isA<JwtException>()),
    );
  });

  test('memory denylist forgets entries after expiry', () async {
    final denylist = MemoryJwtDenylist(clock: clock);
    await denylist.add('abc', fixed.add(const Duration(minutes: 1)));
    expect(await denylist.contains('abc'), isTrue);
    now = fixed.add(const Duration(minutes: 2));
    expect(await denylist.contains('abc'), isFalse);
  });
}
