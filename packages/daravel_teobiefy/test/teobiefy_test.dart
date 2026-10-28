import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:daravel/daravel.dart';
import 'package:daravel_teobiefy/daravel_teobiefy.dart';
import 'package:test/test.dart';

/// Made by PHP's sodium (libsodium) from fixed seeds, with
/// sodium_crypto_kx_seed_keypair(str_repeat("\x01" / "\x02", 32)):
/// crypto_kx_server_session_keys, and ChaCha20-Poly1305 IETF both ways with
/// the nonce str_repeat("\x07", 12). Test keys, not secrets.
const _libsodium = (
  serverSecretKey: '9Azq+G5XdpIzMrjY/TvvhJytsZxplrwnKvH2SNlWakw=',
  serverPublicKey: 'qy/KMomDIsII+y2rUEi9Q8NVxkMPWIiXy1dJYc+pgG8=',
  clientPublicKey: '/Dszk2elIl1TqS04AyOv0DXXgXttG+R9lG9rCanL3AY=',
  serverRx: '/y45gHm9Ho68ksmO3qeSFiw6NF09jKDn2Q6iHyvZG4s=',
  serverTx: 'tB/wBb9pdJBYnvMwbtnAJQ0mKUcwWWa4qop+Q1pz3y4=',
  nonce: 'BwcHBwcHBwcHBwcH',
  // The client's request {"name":"Ana","age":17}, sealed with its tx key.
  requestEnc: '/pW9fJXcmFhWKPsC3helzNuTd/ywe0uZRnlXBN+2RbJe88AA68Iy',
  // The server's "hello", sealed with its tx key.
  responseEnc: '3gNrPi9pTZPHXECDMPruq+jjSZKs',
);

/// The client's side of crypto_kx (crypto_kx_client_session_keys): its tx
/// is the server's rx.
Future<({List<int> rx, List<int> tx})> _clientKeys(
  SimpleKeyPair client,
  List<int> serverPublicKey,
) async {
  final shared = await (await X25519().sharedSecretKey(
    keyPair: client,
    remotePublicKey: SimplePublicKey(serverPublicKey, type: KeyPairType.x25519),
  )).extractBytes();
  final clientPublicKey = (await client.extractPublicKey()).bytes;
  final hash = (await Blake2b().hash([
    ...shared,
    ...clientPublicKey,
    ...serverPublicKey,
  ])).bytes;
  // libsodium: the client rx is the first half, its tx the second.
  return (rx: hash.sublist(0, 32), tx: hash.sublist(32));
}

/// The content of a zstd frame of raw blocks (what [TeobiefyCrypto.zstdFrame]
/// writes); a real decoder checked the format separately.
List<int> _unframe(List<int> frame) {
  expect(frame.sublist(0, 4), [0x28, 0xB5, 0x2F, 0xFD]);
  expect(frame[4], 0xE0);
  final out = <int>[];
  var at = 13;
  while (true) {
    final header = frame[at] | frame[at + 1] << 8 | frame[at + 2] << 16;
    final size = header >> 3;
    expect((header >> 1) & 3, 0, reason: 'raw block');
    out.addAll(frame.sublist(at + 3, at + 3 + size));
    at += 3 + size;
    if (header & 1 == 1) {
      break;
    }
  }
  expect(at, frame.length);
  return out;
}

void main() {
  group('libsodium', () {
    test('crypto_kx server session keys', () async {
      final server = await TeobiefyCrypto.keyPairFrom(
        base64.decode(_libsodium.serverSecretKey),
      );
      expect(
        base64.encode((await server.extractPublicKey()).bytes),
        _libsodium.serverPublicKey,
      );
      final keys = await TeobiefyCrypto.serverSessionKeys(
        server,
        base64.decode(_libsodium.clientPublicKey),
      );
      expect(base64.encode(keys.rx), _libsodium.serverRx);
      expect(base64.encode(keys.tx), _libsodium.serverTx);
    });

    test('chacha20poly1305 IETF both ways', () async {
      final nonce = base64.decode(_libsodium.nonce);
      final request = await TeobiefyCrypto.open(
        base64.decode(_libsodium.requestEnc),
        base64.decode(_libsodium.serverRx),
        nonce,
      );
      expect(utf8.decode(request), '{"name":"Ana","age":17}');
      final response = await TeobiefyCrypto.seal(
        utf8.encode('hello'),
        base64.decode(_libsodium.serverTx),
        nonce,
      );
      expect(base64.encode(response), _libsodium.responseEnc);
      await expectLater(
        TeobiefyCrypto.open(
          response,
          base64.decode(_libsodium.serverRx),
          nonce,
        ),
        throwsA(isA<SecretBoxAuthenticationError>()),
      );
    });

    test('refuses a key that is not one', () async {
      final server = await TeobiefyCrypto.newKeyPair();
      await expectLater(
        TeobiefyCrypto.serverSessionKeys(server, List.filled(31, 1)),
        throwsArgumentError,
      );
      // The neutral point: an all-zero shared secret, as libsodium refuses.
      await expectLater(
        TeobiefyCrypto.serverSessionKeys(server, List.filled(32, 0)),
        throwsArgumentError,
      );
    });

    test('a zstd frame of raw blocks, across block boundaries', () {
      for (final size in [0, 5, 131072, 131073, 300000]) {
        final data = [for (var i = 0; i < size; i++) i % 251];
        expect(_unframe(TeobiefyCrypto.zstdFrame(data)), data);
      }
    });
  });

  group('the middleware', () {
    late Application app;
    // How many times the /profile handler ran: a refused request must not
    // have reached it.
    var profileHits = 0;

    Future<Application> boot([Map<String, String> env = const {}]) async {
      profileHits = 0;
      final application = Application.configure(basePath: '.')
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'APP_KEY': 'base64:${base64.encode(List<int>.filled(32, 7))}',
            ...env,
          })
          .withTeobiefy()
          .withRouting(
            apiPrefix: '/api',
            api: (router) {
              router.post('/v1/session-key', Teobiefy.handshake);
              router.group(middleware: const ['teobiefy'], (r) {
                r.post('/profile', (request) async {
                  profileHits++;
                  final input = await request.all();
                  return Teobiefy.api(200, 'ok', {
                    'echo': input['name'],
                    'seen': input.keys.toList()..sort(),
                  });
                });
                r.get('/plain', (request) => Response.text('plain'));
              });
            },
          )
          .create();
      await application.boot();
      addTearDown(application.shutdown);
      return application;
    }

    Future<Map<String, Object?>> json(Response response) async =>
        jsonDecode(await response.bodyText()) as Map<String, Object?>;

    Future<
      ({
        String id,
        ({List<int> rx, List<int> tx}) keys,
        Map<String, Object?> body,
      })
    >
    handshake() async {
      final client = await X25519().newKeyPair();
      final response = await app.handle(
        Request.fake(
          method: 'POST',
          path: '/api/v1/session-key',
          json: {
            'client_public_key': base64.encode(
              (await client.extractPublicKey()).bytes,
            ),
          },
        ),
      );
      expect(response.status, 200);
      final body = await json(response);
      final data = body['data']! as Map<String, Object?>;
      return (
        id: data['session_id']! as String,
        keys: await _clientKeys(
          client,
          base64.decode(data['server_public_key']! as String),
        ),
        body: body,
      );
    }

    Future<Response> send(
      String sessionId,
      List<int> key,
      Map<String, Object?> payload, {
      bool tamper = false,
    }) async {
      final nonce = TeobiefyCrypto.nonce();
      final sealed = await TeobiefyCrypto.seal(
        utf8.encode(jsonEncode(payload)),
        key,
        nonce,
      );
      if (tamper) {
        sealed[0] ^= 1;
      }
      return app.handle(
        Request.fake(
          method: 'POST',
          path: '/api/profile',
          headers: {'X-Session-Id': sessionId},
          json: {
            'data_enc': base64.encode(sealed),
            'nonce': base64.encode(nonce),
            'extra': 'clear',
          },
        ),
      );
    }

    test('handshake, then an encrypted request and response', () async {
      app = await boot();
      final session = await handshake();
      expect(session.id, matches(RegExp(r'^[a-f0-9]{64}$')));
      expect(session.body['message'], 'Sesi enkripsi berhasil dibuat.');
      expect((session.body['data']! as Map)['expires_in'], 1800);
      expect(session.body['data_count'], 3, reason: "obiefy's api()");

      final response = await send(session.id, session.keys.tx, {'name': 'Ana'});
      expect(response.status, 200);
      final body = await json(response);
      expect(body.containsKey('data'), isFalse);
      expect(body['status'], 200);
      expect(body['data_count'], 2, reason: 'left as it was');
      final clear = await TeobiefyCrypto.open(
        base64.decode(body['data_enc']! as String),
        session.keys.rx,
        base64.decode(body['nonce']! as String),
      );
      // v1: base64 of the zstd frame of the JSON.
      final data = jsonDecode(
        utf8.decode(_unframe(base64.decode(utf8.decode(clear)))),
      );
      expect(data, {
        'echo': 'Ana',
        'seen': ['extra', 'name'],
      });
    });

    test('LIBSODIUM_PAYLOAD_V2_ENABLED seals the zstd bytes', () async {
      app = await boot({'LIBSODIUM_PAYLOAD_V2_ENABLED': 'true'});
      final session = await handshake();
      final body = await json(
        await send(session.id, session.keys.tx, {'name': 'Ana'}),
      );
      expect(body['enc_v'], 2);
      final clear = await TeobiefyCrypto.open(
        base64.decode(body['data_enc']! as String),
        session.keys.rx,
        base64.decode(body['nonce']! as String),
      );
      expect(clear.sublist(0, 4), [0x28, 0xB5, 0x2F, 0xFD]);
      expect(
        jsonDecode(utf8.decode(_unframe(clear))),
        containsPair('echo', 'Ana'),
      );
    });

    test('no session: 409 SESSION_KEY_REQUIRED, never plain data', () async {
      app = await boot();
      final unknown = 'a' * 64;
      final refused = await send(unknown, List.filled(32, 1), {'name': 'x'});
      expect(refused.status, 409);
      expect(await json(refused), {
        'status': 409,
        'message': 'Sesi enkripsi tidak tersedia atau telah kedaluwarsa.',
        'data': null,
        'type': 'SESSION_KEY_REQUIRED',
      });
      // A clear body with no session is refused before the handler runs:
      // the 409 used to come after the handler had acted on the clear data.
      final response = await app.handle(
        Request.fake(method: 'POST', path: '/api/profile', json: {'a': 1}),
      );
      expect(response.status, 409);
      expect(profileHits, 0, reason: 'the handler must not see clear data');
      // Responses without data pass as they are.
      final plain = await app.handle(Request.fake(path: '/api/plain'));
      expect(await plain.bodyText(), 'plain');
    });

    test('LIBSODIUM_STRICT_PAYLOAD keeps clear data out', () async {
      app = await boot({'LIBSODIUM_STRICT_PAYLOAD': 'true'});
      final session = await handshake();
      // The clear 'extra' sent beside data_enc (see send) is dropped.
      final body = await json(
        await send(session.id, session.keys.tx, {'name': 'Ana'}),
      );
      final clear = await TeobiefyCrypto.open(
        base64.decode(body['data_enc']! as String),
        session.keys.rx,
        base64.decode(body['nonce']! as String),
      );
      final data = jsonDecode(
        utf8.decode(_unframe(base64.decode(utf8.decode(clear)))),
      );
      expect(data, {
        'echo': 'Ana',
        'seen': ['name'],
      });
      // A clear body from a client that holds a session is refused.
      final plain = await app.handle(
        Request.fake(
          method: 'POST',
          path: '/api/profile',
          headers: {'X-Session-Id': session.id},
          json: {'name': 'clear'},
        ),
      );
      expect(plain.status, 406);
      expect(profileHits, 1);
    });

    test('a tampered payload is 406', () async {
      app = await boot();
      final session = await handshake();
      final response = await send(session.id, session.keys.tx, {
        'name': 'Ana',
      }, tamper: true);
      expect(response.status, 406);
      expect((await json(response))['message'], 'Invalid payload');
      expect(profileHits, 0);
    });

    test(
      'a replayed payload is 406; a forgery does not burn its nonce',
      () async {
        app = await boot();
        final session = await handshake();
        final nonce = TeobiefyCrypto.nonce();
        final sealed = await TeobiefyCrypto.seal(
          utf8.encode(jsonEncode({'name': 'Ana'})),
          session.keys.tx,
          nonce,
        );
        Future<Response> submit(List<int> body) => app.handle(
          Request.fake(
            method: 'POST',
            path: '/api/profile',
            headers: {'X-Session-Id': session.id},
            json: {
              'data_enc': base64.encode(body),
              'nonce': base64.encode(nonce),
            },
          ),
        );
        // A forged body under the same nonce fails its tag and leaves the
        // nonce unused, so the genuine request is not locked out by it.
        final forged = Uint8List.fromList(sealed)..[0] ^= 1;
        expect((await submit(forged)).status, 406);
        final first = await submit(sealed);
        expect(first.status, 200);
        expect(profileHits, 1);
        // The captured body sent again: same session, same nonce.
        final replay = await submit(sealed);
        expect(replay.status, 406);
        expect((await json(replay))['message'], 'Invalid payload');
        expect(profileHits, 1, reason: 'a replay must not reach the handler');
        // A fresh nonce from the same session still works.
        expect(
          (await send(session.id, session.keys.tx, {'name': 'B'})).status,
          200,
        );
      },
    );

    test(
      'an invalid public key is 422; sessions outlive one isolate',
      () async {
        app = await boot();
        final response = await app.handle(
          Request.fake(
            method: 'POST',
            path: '/api/v1/session-key',
            json: {'client_public_key': base64.encode(List.filled(16, 1))},
          ),
        );
        expect(response.status, 422);
        expect(
          (await json(response))['message'],
          'Client public key tidak valid.',
        );
        await app.run(() async {
          expect(
            Teobiefy.service.sessions.cache.store.scope,
            isNot(StateScope.isolate),
            reason: 'the default memory store is per isolate',
          );
        });
      },
    );

    test('the legacy key only when enabled, with a warning', () async {
      final legacy = base64.encode(List.filled(32, 9));
      app = await boot({
        'LIBSODIUM_LEGACY_KEY_ENABLED': 'true',
        'LIBSODIUM_LEGACY_KEY': legacy,
      });
      final response = await send('', base64.decode(legacy), {'name': 'Old'});
      expect(response.status, 200);
      final issues = TeobiefyConfig.check(
        app.env,
        app.config,
      ).map((i) => i.level);
      expect(issues, [ConfigIssueLevel.warning]);
      // A client that presents a session id the store does not know
      // (expired, another server) is told to handshake again, not given
      // the 406 the legacy key would produce for its body.
      final expired = await send('b' * 64, base64.decode(legacy), {
        'name': 'Old',
      });
      expect(expired.status, 409);
      expect((await json(expired))['type'], 'SESSION_KEY_REQUIRED');
      expect(profileHits, 1);
    });
  });

  test('no key file or secret in the package', () {
    for (final file in Directory('lib').listSync(recursive: true)) {
      if (file is File) {
        expect(file.readAsStringSync(), isNot(contains('PRIVATE KEY')));
      }
    }
    expect(Uint8List(0), isEmpty);
  });
}
