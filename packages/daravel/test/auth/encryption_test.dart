import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  final key = Encrypter.parseKey(Encrypter.generateKey());
  final other = Encrypter.parseKey(Encrypter.generateKey());

  Map<String, Object?> payloadOf(String encrypted) =>
      jsonDecode(utf8.decode(base64.decode(encrypted))) as Map<String, Object?>;

  test('generateKey/parseKey produce 32-byte keys and reject garbage', () {
    expect(Encrypter.generateKey(), startsWith('base64:'));
    expect(key, hasLength(32));
    expect(
      () => Encrypter.parseKey('base64:***'),
      throwsA(isA<EncryptException>()),
    );
    expect(() => Encrypter([1, 2, 3]), throwsA(isA<EncryptException>()));
  });

  test('AES-256-GCM round trip with a Laravel-shaped payload', () async {
    final crypt = Encrypter(key, cipher: .aes256gcm);
    final encrypted = await crypt.encryptString('hello daravel');
    final payload = payloadOf(encrypted);
    expect(payload.keys, ['iv', 'value', 'mac', 'tag']);
    expect(base64.decode(payload['iv']! as String), hasLength(12));
    expect(payload['mac'], '');
    expect(base64.decode(payload['tag']! as String), hasLength(16));
    expect(await crypt.decryptString(encrypted), 'hello daravel');
    expect(await crypt.encryptString('hello daravel'), isNot(encrypted));
  });

  test('AES-256-CBC + HMAC round trip (Laravel aes-256-cbc shape)', () async {
    final crypt = Encrypter(key, cipher: .aes256cbc);
    final encrypted = await crypt.encryptString('shared with laravel');
    final payload = payloadOf(encrypted);
    expect(base64.decode(payload['iv']! as String), hasLength(16));
    expect(payload['tag'], '');
    expect(payload['mac'], matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(await crypt.decryptString(encrypted), 'shared with laravel');
    // A GCM-configured encrypter still reads CBC payloads (cipher is
    // detected from the payload), and vice versa.
    expect(
      await Encrypter(key).decryptString(encrypted),
      'shared with laravel',
    );
    final gcm = await Encrypter(key).encryptString('x');
    expect(await crypt.decryptString(gcm), 'x');
  });

  test(
    'encrypt/decrypt carry PHP-serialized values with type checks',
    () async {
      final crypt = Encrypter(key);
      final encrypted = await crypt.encrypt({
        'id': 7,
        'roles': ['admin'],
      });
      // The clear text is what Laravel's Crypt::encrypt would have encrypted.
      expect(
        await crypt.decryptString(encrypted),
        'a:2:{s:2:"id";i:7;s:5:"roles";a:1:{i:0;s:5:"admin";}}',
      );
      final decoded = await crypt.decrypt<Map<String, Object?>>(encrypted);
      expect(decoded['id'], 7);
      expect(decoded['roles'], ['admin']);
      expect(
        () => crypt.decrypt<List<Object?>>(encrypted),
        throwsA(isA<DecryptException>()),
      );
    },
  );

  test('decrypt reads a Laravel Crypt::encrypt payload', () async {
    // Laravel 12 (APP_CIPHER=AES-256-CBC, this key):
    // Crypt::encrypt(['id' => 7, 'tags' => ['a', 'b']]).
    final crypt = Encrypter(key);
    final laravel = await crypt.encryptString(
      'a:2:{s:2:"id";i:7;s:4:"tags";a:2:{i:0;s:1:"a";i:1;s:1:"b";}}',
    );
    expect(await crypt.decrypt<Map<String, Object?>>(laravel), {
      'id': 7,
      'tags': ['a', 'b'],
    });
  });

  test('decrypt still reads a JSON payload from Daravel 1.17', () async {
    final crypt = Encrypter(key);
    final legacy = await crypt.encryptString('{"id":7,"roles":["admin"]}');
    expect(await crypt.decrypt<Map<String, Object?>>(legacy), {
      'id': 7,
      'roles': ['admin'],
    });
    final junk = await crypt.encryptString('not serialized, not json');
    expect(
      () => crypt.decrypt<Object?>(junk),
      throwsA(isA<DecryptException>()),
    );
  });

  test('tampering, wrong keys and junk raise DecryptException', () async {
    final crypt = Encrypter(key);
    final encrypted = await crypt.encryptString('secret');
    final payload = payloadOf(encrypted);
    final valueBytes = base64.decode(payload['value']! as String);
    valueBytes[0] ^= 0xff;
    payload['value'] = base64.encode(valueBytes);
    final tampered = base64.encode(utf8.encode(jsonEncode(payload)));
    expect(
      () => crypt.decryptString(tampered),
      throwsA(isA<DecryptException>()),
    );
    expect(
      () => Encrypter(other).decryptString(encrypted),
      throwsA(isA<DecryptException>()),
    );
    expect(
      () => crypt.decryptString('not base64!'),
      throwsA(isA<DecryptException>()),
    );
    expect(
      () => crypt.decryptString(base64.encode(utf8.encode('{"iv":1}'))),
      throwsA(isA<DecryptException>()),
    );

    final cbc = Encrypter(key, cipher: .aes256cbc);
    final cbcPayload = payloadOf(await cbc.encryptString('secret'));
    cbcPayload['mac'] = '0' * 64;
    expect(
      () =>
          cbc.decryptString(base64.encode(utf8.encode(jsonEncode(cbcPayload)))),
      throwsA(isA<DecryptException>()),
    );
  });

  test('key rotation: previous keys still decrypt, new key encrypts', () async {
    final old = Encrypter(key);
    final encrypted = await old.encryptString('rotated');
    final rotated = Encrypter(other, previousKeys: [key]);
    expect(await rotated.decryptString(encrypted), 'rotated');
    final fresh = await rotated.encryptString('new');
    expect(() => old.decryptString(fresh), throwsA(isA<DecryptException>()));
    final fromEnv = Encrypter.fromAppKey(
      'base64:${base64.encode(other)}',
      previousKeys: ['base64:${base64.encode(key)}', ''],
    );
    expect(await fromEnv.decryptString(encrypted), 'rotated');
  });
}
