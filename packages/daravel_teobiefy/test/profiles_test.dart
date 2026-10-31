import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel_teobiefy/daravel_teobiefy.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// Made by PHP 8.3's sodium and OpenSSL, as `PayloadCipher` and
/// `PayloadSigner` call them: key 0x11 repeated, signing key 0x22 repeated,
/// payload `{"name":"Ana","age":17}`. Test keys, not secrets.
const _php = (
  key: 'ERERERERERERERERERERERERERERERERERERERERERE=',
  signingKey: 'IiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiIiI=',
  xchacha: 'wYYZ6BUOIQ2g1UbF7MHct+wiXsR9hAlcA9svBQcrOvoSzbbQWWi4',
  xnonce: 'MzMzMzMzMzMzMzMzMzMzMzMzMzMzMzMz',
  chacha: 'OATzkWG4obJnW2jan/pdTenJc2koB5whgfsz15FcoCeMd/GCjArV',
  cnonce: 'RERERERERERERERE',
  gcm: 'VNilC6XZOvAqxrERdIkq/zN8NpaCnQtyxLf1rlPpVEHceIx2PxVi',
  gnonce: 'VVVVVVVVVVVVVVVV',
  hmac: '3GmBivFjTAhfjGbtEuz9hLS7tAKp2S9iHmRgG8x58BI=',
);

const String _payload = '{"name":"Ana","age":17}';

TeobiefyProfiles _profiles({
  String cipher = 'xchacha20-poly1305',
  bool replay = false,
  CacheRepository? store,
  int minCompress = 1024,
  int maxBytes = 10485760,
  Map<String, String> keys = const {},
  String? activeKid,
}) => TeobiefyProfiles(
  TeobiefyProfilesConfig(
    cipher: cipher,
    replayProtection: replay,
    minCompressBytes: minCompress,
    maxDecompressedBytes: maxBytes,
  ),
  encryption: TeobiefyKeyRing(
    keys: keys,
    activeKid: activeKid,
    legacyKey: _php.key,
  ),
  signing: TeobiefyKeyRing(legacyKey: _php.signingKey),
  replayStore: store,
);

void main() {
  group('reads what PHP wrote', () {
    for (final (cipher, data, nonce) in [
      ('xchacha20-poly1305', _php.xchacha, _php.xnonce),
      ('chacha20-poly1305-ietf', _php.chacha, _php.cnonce),
      ('aes-256-gcm', _php.gcm, _php.gnonce),
    ]) {
      test(cipher, () async {
        final decoded = await _profiles(cipher: cipher).decodeRequest({
          'data_enc': data,
          'nonce': nonce,
          'cipher': cipher,
        }, TeobiefyProfile.encrypted);
        expect(decoded, {'name': 'Ana', 'age': 17});
      });
    }

    test('hmac-sha256, the signed bytes being the payload', () async {
      final decoded = await _profiles().decodeRequest({
        'data_comp': base64.encode(utf8.encode(_payload)),
        'sig': _php.hmac,
        'sig_alg': 'hmac-sha256',
      }, TeobiefyProfile.signed);
      expect(decoded, {'name': 'Ana', 'age': 17});
    });
  });

  group('writes what PHP reads', () {
    test('the same bytes as sodium and OpenSSL', () async {
      for (final (cipher, data, nonce) in [
        ('xchacha20-poly1305', _php.xchacha, _php.xnonce),
        ('chacha20-poly1305-ietf', _php.chacha, _php.cnonce),
        ('aes-256-gcm', _php.gcm, _php.gnonce),
      ]) {
        final sealed = await _profiles(cipher: cipher).encrypt(
          utf8.encode(_payload),
          base64.decode(nonce),
          base64.decode(_php.key),
        );
        expect(base64.encode(sealed), data, reason: cipher);
      }
    });

    test('the signed envelope keeps the rest of the response', () async {
      final envelope = await _profiles().transformResponse({
        'status': 200,
        'message': 'ok',
        'data': {'a': 1},
        'data_count': 1,
      }, TeobiefyProfile.signed);
      expect(envelope.keys, [
        'status',
        'message',
        'data_count',
        'data_comp',
        'compression',
        'sig',
        'sig_alg',
      ]);
      expect(envelope['compression'], 'none');
    });

    test('kid only with a named key', () async {
      final named = await _profiles(
        keys: {'v2': _php.key},
        activeKid: 'v2',
      ).transformResponse({'data': 1}, TeobiefyProfile.encrypted);
      expect(named['kid'], 'v2');
      final legacy = await _profiles().transformResponse({
        'data': 1,
      }, TeobiefyProfile.encrypted);
      expect(legacy.containsKey('kid'), isFalse);
    });

    test('compression waits for min_bytes', () async {
      final small = await _profiles().transformResponse({
        'data': 'x',
      }, TeobiefyProfile.compressed);
      expect(small['compression'], 'none');
      final large = await _profiles(minCompress: 1)
          .transformResponse({'data': 'x'}, TeobiefyProfile.compressed);
      expect(large['compression'], 'zstd');
      expect(base64.decode(large['data_comp']! as String).sublist(0, 4), [
        0x28,
        0xB5,
        0x2F,
        0xFD,
      ]);
    });
  });

  group('round trips', () {
    for (final profile in TeobiefyProfile.values) {
      test(profile.label, () async {
        if (profile == TeobiefyProfile.plain) {
          return;
        }
        final profiles = _profiles(minCompress: 1);
        final sealed = await profiles.transformResponse({
          'data': {'name': 'Ana é'},
        }, profile);
        expect(sealed.containsKey('data'), isFalse);
        expect(await profiles.decodeRequest(sealed, profile), {
          'name': 'Ana é',
        });
      });
    }
  });

  group('refuses', () {
    Future<Map<String, Object?>> sealed([TeobiefyProfiles? p]) =>
        (p ?? _profiles()).transformResponse({
          'data': {'a': 1},
        }, TeobiefyProfile.encrypted);

    test('a tampered ciphertext', () async {
      final body = await sealed();
      final bytes = base64.decode(body['data_enc']! as String);
      bytes[0] ^= 1;
      expect(
        _profiles().decodeRequest({
          ...body,
          'data_enc': base64.encode(bytes),
        }, TeobiefyProfile.encrypted),
        throwsA(isA<TeobiefyInvalidPayload>()),
      );
    });

    test('another cipher, a missing field, an unknown key id', () async {
      final body = await sealed();
      for (final broken in [
        {...body, 'cipher': 'aes-256-gcm'},
        {...body}..remove('nonce'),
        {...body, 'kid': 'nope'},
        {...body, 'data_enc': 'not base64!'},
      ]) {
        expect(
          _profiles().decodeRequest(broken, TeobiefyProfile.encrypted),
          throwsA(isA<TeobiefyInvalidPayload>()),
          reason: '$broken',
        );
      }
    });

    test('a bad signature or another algorithm', () async {
      final body = {
        'data_comp': base64.encode(utf8.encode(_payload)),
        'sig': base64.encode(List.filled(32, 7)),
      };
      expect(
        _profiles().decodeRequest(body, TeobiefyProfile.signed),
        throwsA(isA<TeobiefyInvalidSignature>()),
      );
      expect(
        _profiles().decodeRequest({
          ...body,
          'sig': _php.hmac,
          'sig_alg': 'none',
        }, TeobiefyProfile.signed),
        throwsA(isA<TeobiefyInvalidSignature>()),
      );
    });

    test('a frame with compressed blocks, and a zip bomb', () async {
      // A real frame of PHP's zstd_compress().
      final compressed = File('test/fixtures/zstd/small.zst').readAsBytesSync();
      expect(
        await _profiles().decodeRequest({
          'data_comp': base64.encode(compressed),
          'compression': 'zstd',
        }, TeobiefyProfile.compressed),
        containsPair('status', 'ok'),
      );
      // One RLE block of 1000 bytes.
      final header = 1 | (1 << 1) | (1000 << 3);
      final bomb = Uint8List.fromList([
        0x28, 0xB5, 0x2F, 0xFD, 0x20, 0, //
        header & 0xFF, (header >> 8) & 0xFF, (header >> 16) & 0xFF, 0x41,
      ]);
      expect(
        _profiles(maxBytes: 100).decodeRequest({
          'data_comp': base64.encode(bomb),
          'compression': 'zstd',
        }, TeobiefyProfile.compressed),
        throwsA(isA<TeobiefyPayloadTooLarge>()),
      );
    });
  });

  test('an oversized field is refused before it is decoded', () {
    final profiles = _profiles(maxBytes: 100);
    // Not base64, so reaching the decoder would answer otherwise.
    expect(
      profiles.decodeRequest({
        'data_comp': '!' * 10000,
        'compression': 'zstd',
      }, TeobiefyProfile.compressed),
      throwsA(isA<TeobiefyPayloadTooLarge>()),
    );
  });

  test('a field within the limit reaches the decoder', () {
    expect(
      _profiles(maxBytes: 100).decodeRequest({
        'data_comp': '!' * 100,
        'compression': 'zstd',
      }, TeobiefyProfile.compressed),
      throwsA(isA<TeobiefyInvalidPayload>()),
    );
  });

  group('replay protection', () {
    late Directory base;
    late Application app;

    setUp(() async {
      base = Directory.systemTemp.createTempSync('daravel_teobiefy');
      app = Application.configure(basePath: base.path).withEnv({
        'APP_ENV': 'testing',
        'DB_DATABASE': ':memory:',
        'CACHE_STORE': 'memory',
      }).create();
      await app.boot();
    });

    tearDown(() async {
      Clock.restore();
      await app.shutdown();
      base.deleteSync(recursive: true);
    });

    test('a body works once, and only inside the window', () async {
      await app.run(() async {
        final profiles = _profiles(
          replay: true,
          store: app.container.make<CacheManager>().store(),
        );
        final body = await profiles.transformResponse({
          'data': {'a': 1},
        }, TeobiefyProfile.encrypted);
        expect(await profiles.decodeRequest(body, TeobiefyProfile.encrypted), {
          'a': 1,
        });
        expect(
          profiles.decodeRequest(body, TeobiefyProfile.encrypted),
          throwsA(isA<TeobiefyReplayDetected>()),
        );

        final stale = await profiles.transformResponse({
          'data': {'a': 2},
        }, TeobiefyProfile.encrypted);
        Clock.travelTo(Clock.now().add(const Duration(seconds: 301)));
        expect(
          profiles.decodeRequest(stale, TeobiefyProfile.encrypted),
          throwsA(isA<TeobiefyReplayDetected>()),
        );
      });
    });
  });

  group('middleware', () {
    late Directory base;
    late Application app;
    late TestClient client;

    setUp(() async {
      base = Directory.systemTemp.createTempSync('daravel_teobiefy');
      app = Application.configure(basePath: base.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'TEOBIEFY_ENCRYPTION_KEY': _php.key,
            'TEOBIEFY_SIGNING_KEY': _php.signingKey,
          })
          .withLogLevel(LogLevel.error)
          .withTeobiefyProfiles(
            responseProfiles: const {
              'secret/*': 'encrypted',
              'named': 'signed',
            },
            requestProfiles: const {'secret/*': 'encrypted'},
          )
          .withRouting(
            web: (router) => router.group((r) {
              r.post(
                '/secret/echo',
                (request) async => Teobiefy.api(200, 'ok', await request.all()),
              );
              r.get('/open', (_) => Teobiefy.api(200, 'ok', {'a': 1}));
              r
                  .get('/by-name', (_) => Teobiefy.api(200, 'ok', {'a': 1}))
                  .name('named');
              r
                  .get('/explicit', (_) => Teobiefy.api(200, 'ok', {'a': 1}))
                  .middleware(['teobiefy.profile:signed,plain']);
              r.get('/no-data', (_) => {'other': 1});
            }, middleware: const ['teobiefy.profile']),
          )
          .create();
      await app.boot();
      client = TestClient(app);
    });

    tearDown(() async {
      await app.shutdown();
      base.deleteSync(recursive: true);
    });

    test('plain stays as it is', () async {
      expect((await client.get('/open')).jsonMap['data'], {'a': 1});
      expect((await client.get('/no-data')).jsonMap, {'other': 1});
    });

    test('a pattern on the path decrypts and encrypts', () async {
      final body = await app.run(
        () => App.make<TeobiefyProfiles>().transformResponse({
          'data': {'name': 'Ana'},
        }, TeobiefyProfile.encrypted),
      );
      final response = await client.post(
        '/secret/echo',
        json: {...body, 'clear': 'kept'},
      );
      response.assertOk();
      expect(response.jsonMap.containsKey('data'), isFalse);
      expect(response.jsonMap['status'], 200);
      final clear = await app.run(
        () => App.make<TeobiefyProfiles>().decodeRequest(
          response.jsonMap,
          TeobiefyProfile.encrypted,
        ),
      );
      expect(clear, {'clear': 'kept', 'name': 'Ana'});
    });

    test('a route name, and parameters over patterns', () async {
      expect((await client.get('/by-name')).jsonMap.containsKey('sig'), isTrue);
      expect(
        (await client.get('/explicit')).jsonMap.containsKey('sig'),
        isTrue,
      );
    });

    test('statuses as PayloadDecryptMiddleware answers', () async {
      final invalid = await client.post(
        '/secret/echo',
        json: {'data_enc': 'x'},
      );
      expect(invalid.status, 406);
      expect(invalid.jsonMap['message'], 'Invalid payload');
    });
  });

  test('profile names are config/teobiefy.php\'s', () {
    expect(
      TeobiefyProfile.from('compressed_encrypted'),
      isA<TeobiefyProfile>(),
    );
    expect(() => TeobiefyProfile.from('nope'), throwsArgumentError);
  });
}
