import 'dart:convert';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:daravel_teobiefy/daravel_teobiefy.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

Uint8List _hex(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

/// NIST SP 800-38A, F.2.5 CBC-AES256.Encrypt: four blocks, no padding. With
/// PKCS#7 the same ciphertext is followed by one block of 0x10 bytes, whose
/// value `openssl enc -aes-256-cbc` gave (the Laravel side is OpenSSL).
const _nist = (
  key: '603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4',
  iv: '000102030405060708090a0b0c0d0e0f',
  plain:
      '6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51'
      '30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710',
  cipher:
      'f58c4c04d6e5f1ba779eabfb5f7bfbd69cfc4e967edb808d679f777bc6702c7d'
      '39f23369a9d9bacfa530e26304231461b2eb05e2c39be9fcda6c19078c6a9d1b',
  padding: '3f461796d6b0d6b2e0c2a72b4d80e644',
);

/// `openssl enc -aes-256-cbc -K <key> -iv <iv>` (PKCS#7, as
/// `openssl_encrypt(..., OPENSSL_RAW_DATA, ...)`) over JSON texts, with the
/// key 00..1f and the IV 0f..00. Test values, not secrets.
const _openssl = (
  key: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
  iv: 'Dw4NDAsKCQgHBgUEAwIBAA==',
  // {"name":"Ana","age":17}: 23 bytes, two blocks.
  json: 'nKuqo+VNJHl5UlZG4BQ5VTRO7OXz6J3SsQILs75mXL4=',
  // "": one block of padding only.
  empty: '2vAVsV0lVEqVELhPttlO/Q==',
  // 0123456789abcdef: one full block, then a full block of padding.
  block: 'eGKgcdoZ8yhtzUynypxuPu/BDT+j1kbmhytpvac1Chk=',
  // {"url":"https:\/\/x.id\/a","nama":"É"}: PHP's json_encode escapes the
  // slashes; the É is UTF-8.
  php: '7cJgto/TddQncVkKBmyh7NrFu3qNwXRFqUfybLDLMrD2JcyKbI5J729hbFacz0Zv',
);

void main() {
  group('AES-256-CBC', () {
    test('NIST SP 800-38A F.2.5, then one block of PKCS#7 padding', () async {
      final cipher = TeobiefyAesCbc(_hex(_nist.key));
      final iv = _hex(_nist.iv);
      final out = await cipher.encryptBytes(_hex(_nist.plain), iv: iv);
      expect(out.length, 80);
      expect(out.sublist(0, 64), _hex(_nist.cipher));
      expect(out.sublist(64), _hex(_nist.padding));
      expect(await cipher.decryptBytes(out, iv), _hex(_nist.plain));
    });

    test('matches openssl enc (PKCS#7) on JSON texts', () async {
      final cipher = TeobiefyAesCbc.fromKey(_openssl.key);
      final iv = base64.decode(_openssl.iv);
      Future<String> enc(String clear) async =>
          base64.encode(await cipher.encryptBytes(utf8.encode(clear), iv: iv));
      expect(await enc('{"name":"Ana","age":17}'), _openssl.json);
      expect(await enc(''), _openssl.empty);
      expect(await enc('0123456789abcdef'), _openssl.block);
      expect(
        await enc(r'{"url":"https:\/\/x.id\/a","nama":"É"}'),
        _openssl.php,
      );
      // What a client does with the envelope: base64, decrypt, JSON.parse.
      expect(
        await cipher.decrypt({'data_enc': _openssl.json, 'iv': _openssl.iv}),
        {'name': 'Ana', 'age': 17},
      );
      expect(
        await cipher.decrypt({'data_enc': _openssl.php, 'iv': _openssl.iv}),
        {'url': 'https://x.id/a', 'nama': 'É'},
      );
      expect(
        utf8.decode(
          await cipher.decryptBytes(base64.decode(_openssl.empty), iv),
        ),
        '',
      );
    });

    test('round trip: a fresh IV per call, the envelope keys', () async {
      final cipher = TeobiefyAesCbc.fromKey('base64:${_openssl.key}');
      final value = {
        'id': 7,
        'items': ['a', 'b'],
        'nested': {'ok': true, 'none': null},
      };
      final first = await cipher.encrypt(value);
      final second = await cipher.encrypt(value);
      expect(first.keys, ['data_enc', 'iv']);
      expect(base64.decode(first['iv']! as String).length, 16);
      expect(first['iv'], isNot(second['iv']));
      expect(first['data_enc'], isNot(second['data_enc']));
      expect(await cipher.decrypt(first), value);
      expect(await cipher.decrypt(second), value);
      expect(await cipher.decrypt(await cipher.encrypt(null)), isNull);
      expect(await cipher.decrypt(await cipher.encrypt('x')), 'x');
    });

    test(
      'seal replaces data in an obiefy envelope, as OpenSslHelper',
      () async {
        final cipher = TeobiefyAesCbc.fromKey(_openssl.key);
        final sealed = await cipher.seal({
          'status': 200,
          'message': 'ok',
          'data': {'token': 't'},
          'data_count': 1,
        });
        expect(sealed.keys, [
          'status',
          'message',
          'data_count',
          'data_enc',
          'iv',
        ]);
        expect(await cipher.decrypt(sealed), {'token': 't'});
        // Nothing to seal.
        expect(await cipher.seal({'message': 'ok'}), {'message': 'ok'});
      },
    );

    test('refuses what is not an envelope, a key or a ciphertext', () async {
      final cipher = TeobiefyAesCbc.fromKey(_openssl.key);
      final iv = base64.decode(_openssl.iv);
      expect(() => TeobiefyAesCbc(List.filled(16, 1)), throwsArgumentError);
      expect(() => TeobiefyAesCbc.fromKey('not base64!'), throwsArgumentError);
      expect(
        () => TeobiefyAesCbc.fromKey(base64.encode(List.filled(31, 1))),
        throwsArgumentError,
      );
      expect(
        () => cipher.decrypt({'data_enc': _openssl.json}),
        throwsFormatException,
      );
      expect(
        () => cipher.decrypt({'data_enc': 'x', 'iv': _openssl.iv}),
        throwsFormatException,
      );
      expect(
        () => cipher.decrypt({'data_enc': _openssl.json, 'iv': 'AAA='}),
        throwsFormatException,
      );
      // Not whole blocks.
      expect(
        () => cipher.decryptBytes(List.filled(17, 0), iv),
        throwsFormatException,
      );
      expect(() => cipher.decryptBytes(const [], iv), throwsFormatException);
      // A wrong key: the padding does not check out (no MAC: this is luck,
      // not a guarantee).
      final other = TeobiefyAesCbc(List.filled(32, 9));
      expect(
        () => other.decryptBytes(base64.decode(_openssl.json), iv),
        throwsFormatException,
      );
      // The clear text must be JSON.
      final text = await cipher.encryptBytes(utf8.encode('not json'), iv: iv);
      expect(
        () => cipher.decrypt({
          'data_enc': base64.encode(text),
          'iv': _openssl.iv,
        }),
        throwsFormatException,
      );
    });
  });

  group('the teobiefy.aes middleware', () {
    late Application app;
    late TestClient client;
    late TeobiefyAesCbc cipher;
    Map<String, Object?>? seen;

    Future<void> boot([Map<String, String> env = const {}]) async {
      seen = null;
      app = Application.configure(basePath: '.')
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'APP_KEY': 'base64:${base64.encode(List<int>.filled(32, 7))}',
            'OPENSSL_KEY': _openssl.key,
            ...env,
          })
          .withTeobiefyAesCbc()
          .withRouting(
            apiPrefix: '/api',
            api: (router) {
              router
                  .post(
                    '/login',
                    (request) => Teobiefy.api(200, 'ok', {'token': 'abc'}),
                  )
                  .middleware(const ['teobiefy.aes']);
              router
                  .get(
                    '/missing',
                    (request) => Response.json(
                      {'status': 404, 'message': 'nope', 'data': <Object?>[]},
                      status: 404,
                      headers: {'x-trace': 't1'},
                    ),
                  )
                  .middleware(const ['teobiefy.aes']);
              router
                  .get(
                    '/whole',
                    (request) => Response.json({
                      'a': 1,
                      'b': [2],
                    }),
                  )
                  .middleware(const ['teobiefy.aes:body']);
              router
                  .post('/echo', (request) async {
                    seen = Map<String, Object?>.of(await request.all());
                    return Teobiefy.api(200, 'ok', seen);
                  })
                  .middleware(const ['teobiefy.aes:decrypt']);
              router
                  .post('/echo-body', (request) async {
                    seen = Map<String, Object?>.of(await request.all());
                    return Response.json(seen);
                  })
                  .middleware(const ['teobiefy.aes:body,decrypt']);
              router
                  .get(
                    '/no-data',
                    (request) => Response.json({'message': 'clear'}),
                  )
                  .middleware(const ['teobiefy.aes']);
              router
                  .get('/text', (request) => Response.text('plain'))
                  .middleware(const ['teobiefy.aes']);
              router
                  .get(
                    '/php',
                    (request) => Teobiefy.api(200, 'ok', {
                      'url': 'https://x.id/a',
                      'nama': String.fromCharCode(0xC9),
                      'tags': <String, Object?>{},
                    }),
                  )
                  .middleware(const ['teobiefy.aes:php']);
            },
          )
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      client = TestClient(app);
      cipher = TeobiefyAesCbc.fromKey(_openssl.key);
    }

    test('an obiefy envelope leaves with data_enc and iv', () async {
      await boot();
      final response = await client.post(
        '/api/login',
        json: {'email': 'a@b.c'},
      );
      expect(response.status, 200);
      expect(response.headers['content-type'], contains('application/json'));
      final body = response.jsonMap;
      expect(body.keys, ['status', 'message', 'data_count', 'data_enc', 'iv']);
      expect(body['status'], 200);
      expect(body['data_count'], 1, reason: 'left in clear, as OpenSslHelper');
      expect(await cipher.decrypt(body), {'token': 'abc'});
      await app.run(() async {
        expect(await TeobiefyAesCbc.current.decrypt(body), {'token': 'abc'});
      });
    });

    test('keeps the status and the headers', () async {
      await boot();
      final response = await client.get('/api/missing');
      expect(response.status, 404);
      expect(response.headers['x-trace'], 't1');
      final body = response.jsonMap;
      expect(body.containsKey('data'), isFalse);
      expect(await cipher.decrypt(body), <Object?>[]);
    });

    test('teobiefy.aes:body encrypts the whole body', () async {
      await boot();
      final response = await client.get('/api/whole');
      expect(response.status, 200);
      final body = response.jsonMap;
      expect(body.keys, ['data_enc', 'iv']);
      expect(await cipher.decrypt(body), {
        'a': 1,
        'b': [2],
      });
    });

    test('teobiefy.aes:decrypt opens a request envelope', () async {
      await boot();
      final envelope = await cipher.encrypt({'name': 'Ana', 'age': 17});
      final response = await client.post(
        '/api/echo',
        json: {...envelope, 'extra': 'clear', 'name': 'overridden'},
      );
      expect(response.status, 200);
      expect(seen, {'name': 'Ana', 'age': 17, 'extra': 'clear'});
      expect(await cipher.decrypt(response.jsonMap), seen);
      // Both ways on one route.
      final whole = await client.post('/api/echo-body', json: envelope);
      expect(whole.jsonMap.keys, ['data_enc', 'iv']);
      expect(await cipher.decrypt(whole.jsonMap), {'name': 'Ana', 'age': 17});
      // A clear body still passes in this mode.
      final clear = await client.post('/api/echo', json: {'name': 'clear'});
      expect(clear.status, 200);
      expect(seen, {'name': 'clear'});
    });

    test('a request envelope that does not open is 406', () async {
      await boot();
      final envelope = await cipher.encrypt({'name': 'Ana'});
      Future<TestResponse> send(Map<String, Object?> body) =>
          client.post('/api/echo', json: body);
      final tampered = base64.decode(envelope['data_enc']! as String)..[0] ^= 1;
      for (final body in [
        {'data_enc': envelope['data_enc']},
        {'data_enc': 'not base64!', 'iv': envelope['iv']},
        {'data_enc': base64.encode(tampered.sublist(1)), 'iv': envelope['iv']},
        {
          'data_enc': envelope['data_enc'],
          'iv': base64.encode(List.filled(16, 0)),
        },
        // A JSON value that is not an object.
        {...await cipher.encrypt('text')},
      ]) {
        seen = null;
        final response = await send(body);
        expect(response.status, 406, reason: '$body');
        expect(response.jsonMap['message'], 'Invalid payload');
        expect(seen, isNull, reason: 'the handler must not run');
      }
    });

    test('passes what it cannot seal, and what is sealed already', () async {
      await boot();
      expect((await client.get('/api/no-data')).jsonMap, {'message': 'clear'});
      final text = await client.get('/api/text');
      expect(text.body, 'plain');
      await app.run(() async {
        final sealed = await TeobiefyAesCbc.current.seal({'data': 1});
        final response = await const TeobiefyAesCbcMiddleware().handle(
          Request.fake(path: '/x'),
          (_) async => Response.json(sealed),
        );
        expect(jsonDecode(await response.bodyText()), sealed);
      });
    });

    test('the key comes from OPENSSL_KEY, base64: accepted, checked', () async {
      await boot({'OPENSSL_KEY': 'base64:${_openssl.key}'});
      expect(
        await cipher.decrypt(
          (await client.post('/api/login', json: {})).jsonMap,
        ),
        {'token': 'abc'},
      );
      expect(app.config.section<TeobiefyAesCbcConfig>().toMap(), {
        'variable': 'OPENSSL_KEY',
        'key': '********',
      });
      expect(TeobiefyAesCbcConfig.check(app.env, app.config), isEmpty);
      for (final bad in ['', 'short', base64.encode(List.filled(16, 1))]) {
        final broken = Application.configure(basePath: '.')
            .withEnv({
              'APP_ENV': 'testing',
              'DB_DATABASE': ':memory:',
              'APP_KEY': 'base64:${base64.encode(List<int>.filled(32, 7))}',
              'OPENSSL_KEY': bad,
            })
            .withTeobiefyAesCbc()
            .create();
        await expectLater(broken.boot(), throwsA(anything), reason: '[$bad]');
      }
    });

    test('teobiefy.aes:php writes json_encode bytes, inside and out', () async {
      await boot();
      final response = await client.get('/api/php');
      final raw = response.body;
      // The envelope as Laravel's response()->json writes it: every `/`
      // of the base64 escaped, none left bare.
      final backslash = String.fromCharCode(0x5C);
      expect(raw.replaceAll('$backslash/', ''), isNot(contains('/')));
      final body = response.jsonMap;
      final clear = utf8.decode(
        await cipher.decryptBytes(
          base64.decode(body['data_enc']! as String),
          base64.decode(body['iv']! as String),
        ),
      );
      expect(clear, contains('https:$backslash/$backslash/x.id$backslash/a'));
      expect(clear, contains('${backslash}u00c9'));
      // An empty object stays {} (jsonDecode keeps it a map).
      expect(clear, contains('"tags":{}'));
      expect(await cipher.decrypt(body), {
        'url': 'https://x.id/a',
        'nama': String.fromCharCode(0xC9),
        'tags': <String, Object?>{},
      });
    });
    test('unknown alias parameters are refused', () {
      expect(
        () => TeobiefyAesCbcMiddleware.fromParams(const ['strict']),
        throwsArgumentError,
      );
      final both = TeobiefyAesCbcMiddleware.fromParams(const [
        'body',
        'decrypt',
      ]);
      expect(both.wholeBody && both.decryptRequests, isTrue);
    });
  });
}
