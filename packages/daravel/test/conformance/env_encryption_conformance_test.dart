@Tags(['conformance'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `fixtures/laravel_env_encrypted.json` was produced by Laravel 12.70.1's
/// own code (`Illuminate\Encryption\Encrypter::encrypt` and
/// `EnvironmentEncryptCommand::encryptReadableFormat`), i.e. exactly what
/// `php artisan env:encrypt [--readable]` writes, with the key below.
const String laravelKey = 'base64:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';

void main() {
  final fixture = jsonDecode(
    File('test/conformance/fixtures/laravel_env_encrypted.json')
        .readAsStringSync(),
  ) as Map<String, Object?>;
  final contents = fixture['contents']! as String;
  final encrypter = EnvironmentEncrypter(laravelKey);

  test('decrypts php artisan env:encrypt output byte for byte', () async {
    expect(fixture['laravel'], startsWith('12.'));
    expect(await encrypter.decrypt(fixture['default']! as String), contents);
  });

  test('decrypts the --readable format like env:decrypt', () async {
    // Laravel drops comments and blank lines and keeps raw values.
    expect(
      await encrypter.decrypt(fixture['readable']! as String),
      'APP_NAME="Daravel Fixture"\n'
      'APP_KEY=base64:abc==\n'
      "DB_PASSWORD='s3cr3t é'\n"
      'MULTI="line one\nline two"\n',
    );
  });

  test('its own output round-trips in both formats and both ciphers', () async {
    for (final cipher in EncryptionCipher.values) {
      final own = EnvironmentEncrypter(laravelKey, cipher: cipher);
      final whole = await own.encrypt(contents);
      expect(EnvironmentEncrypter.appearsEncrypted(whole), isTrue);
      expect(await own.decrypt(whole), contents);
      final readable = await own.encrypt(contents, readable: true);
      expect(readable, startsWith('APP_NAME=ey'));
      expect(Env.parse(await own.decrypt(readable)), Env.parse(contents));
    }
  });

  test('a raw 32-character key works as in Laravel', () async {
    final raw = EnvironmentEncrypter('0123456789abcdef0123456789abcdef');
    expect(await raw.decrypt(await raw.encrypt('A=1\n')), 'A=1\n');
  });

  test('a wrong key fails loudly', () async {
    final other = EnvironmentEncrypter(Encrypter.generateKey());
    await expectLater(
      other.decrypt(fixture['default']! as String),
      throwsA(isA<DecryptException>()),
    );
  });

  group('Env.load decrypts in memory', () {
    late Directory dir;
    setUp(() => dir = Directory.systemTemp.createTempSync('daravel_env_enc'));
    tearDown(() => dir.deleteSync(recursive: true));

    Future<Env> load(Map<String, String> overrides) => Env.load(
      basePath: dir.path,
      includePlatform: false,
      overrides: overrides,
      decrypt: (payload, key) => EnvironmentEncrypter(key).decrypt(payload),
    );

    test('reads .env.encrypted with LARAVEL_ENV_ENCRYPTION_KEY', () async {
      File(p.join(dir.path, '.env.encrypted'))
          .writeAsStringSync(fixture['default']! as String);
      final env = await load({'LARAVEL_ENV_ENCRYPTION_KEY': laravelKey});
      expect(env.string('APP_NAME'), 'Daravel Fixture');
      expect(env.string('DB_PASSWORD'), 's3cr3t é');
      expect(env.string('MULTI'), 'line one\nline two');
      expect(dir.listSync().map((f) => p.basename(f.path)), [
        '.env.encrypted',
      ], reason: 'nothing is written to disk');
    });

    test('the APP_ENV overlay and plain files layer as usual', () async {
      File(p.join(dir.path, '.env')).writeAsStringSync('A=plain\nB=plain\n');
      final own = EnvironmentEncrypter(laravelKey);
      File(p.join(dir.path, '.env.production.encrypted'))
          .writeAsStringSync(await own.encrypt('B=secret\n', readable: true));
      final env = await load({
        'APP_ENV': 'production',
        'DARAVEL_ENV_ENCRYPTION_KEY': laravelKey,
      });
      expect(env.string('A'), 'plain');
      expect(env.string('B'), 'secret');
    });

    test('without a key the encrypted file is ignored', () async {
      File(p.join(dir.path, '.env.encrypted'))
          .writeAsStringSync(fixture['default']! as String);
      expect((await load(const {})).maybeString('APP_NAME'), isNull);
    });

    test('a wrong key stops the boot with a clear error', () async {
      File(p.join(dir.path, '.env.encrypted'))
          .writeAsStringSync(fixture['default']! as String);
      await expectLater(
        load({'DARAVEL_ENV_ENCRYPTION_KEY': Encrypter.generateKey()}),
        throwsA(
          isA<EnvException>().having(
            (e) => e.message,
            'message',
            contains('Could not decrypt .env.encrypted'),
          ),
        ),
      );
    });
  });
}
