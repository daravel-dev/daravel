@Tags(['conformance'])
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:daravel/daravel.dart';
import 'package:daravel_test/conformance.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import 'conformance_app.dart';

/// Storage formats shared with a Laravel app on the same database:
/// Sanctum tokens, bcrypt hashes, Crypt payloads, table schemas and the
/// `migrations` ledger.
void main() {
  late Application app;
  late TestClient client;

  setUp(() async => (app, client) = await bootConformanceApp());
  tearDown(() => app.shutdown());

  Future<User> createUser() => app.run(
    () async => await User.definition.query().create({
      'name': 'Ana',
      'email': 'ana@example.com',
      'password': await Hash.make('password', driver: .bcrypt),
    }),
  );

  group('Sanctum personal access tokens', () {
    test('plain text is id|random40+crc32b; the row stores sha256', () async {
      final user = await createUser();
      final issued = await app.run(() => Auth.issueToken(user, 'cli'));
      final match = LaravelContract.sanctumPlainTextToken.firstMatch(
        issued.plainTextToken,
      )!;
      final (entropy, checksum) = (match.group(3)!, match.group(4)!);
      expect(checksum, crc32b(utf8.encode(entropy)));

      final row = await app.run(
        () => DB
            .table('personal_access_tokens')
            .where('id', int.parse(match.group(1)!))
            .first(),
      );
      final secret = issued.plainTextToken.split('|').last;
      expect(
        row!['token'],
        crypto.sha256.convert(utf8.encode(secret)).toString(),
      );
      expect(row['tokenable_type'], LaravelContract.morphClass('User'));
      expect(row['tokenable_id'], user.id);
      expect(row['name'], 'cli');
      expect(row['abilities'], '["*"]');
    });

    test('a token row written by Laravel authenticates', () async {
      final user = await createUser();
      // What HasApiTokens::createToken stores for a 48-char secret.
      const secret = 'abcdefghijABCDEFGHIJ0123456789klmnopqrst1a2b3c4d';
      final id = await app.run(
        () => DB.table('personal_access_tokens').insertGetId({
          'tokenable_type': r'App\Models\User',
          'tokenable_id': user.id,
          'name': 'laravel',
          'token': crypto.sha256.convert(utf8.encode(secret)).toString(),
          'abilities': '["*"]',
          'created_at': DateTime.now().toUtc(),
          'updated_at': DateTime.now().toUtc(),
        }),
      );
      (await client.withToken('$id|$secret').get('/api/me')).assertOk();
      // Legacy Sanctum tokens without the id prefix are looked up by hash.
      (await client.withToken(secret).get('/api/me')).assertOk();
      (await client.withToken('$id|wrong').get('/api/me')).assertUnauthorized();
    });

    test('SANCTUM_TOKEN_PREFIX is prepended to the secret', () async {
      await app.shutdown();
      (app, client) = await bootConformanceApp(
        env: {'SANCTUM_TOKEN_PREFIX': 'dv_'},
      );
      final user = await createUser();
      final issued = await app.run(() => Auth.issueToken(user, 'cli'));
      final match = LaravelContract.sanctumPlainTextToken.firstMatch(
        issued.plainTextToken,
      )!;
      expect(match.group(2), 'dv_');
      (await client.withToken(issued.plainTextToken).get('/api/me')).assertOk();
    });

    test('crc32b matches PHP hash("crc32b")', () {
      expect(crc32b(utf8.encode('123456789')), 'cbf43926');
      expect(
        crc32b(utf8.encode('The quick brown fox jumps over the lazy dog')),
        '414fa339',
      );
      expect(crc32b(const <int>[]), '00000000');
    });
  });

  group('Hash (bcrypt)', () {
    test(r'verifies a Laravel $2y$ hash', () async {
      expect(
        await app.run(
          () => Hash.check('password', LaravelContract.bcryptOfPassword),
        ),
        isTrue,
      );
      expect(
        await app.run(
          () => Hash.check('wrong', LaravelContract.bcryptOfPassword),
        ),
        isFalse,
      );
    });

    test(r'bcrypt hashes use the $2y$ prefix Laravel verifies', () async {
      final hash = await app.run(() => Hash.make('secret', driver: .bcrypt));
      expect(hash, startsWith(r'$2y$'));
    });

    test(
      r'verifies $2b$ bcrypt from other runtimes (Bun, Node, Python)',
      () async {
        // Bun.password.hash('secret', {algorithm: 'bcrypt', cost: 10}).
        const bun =
            r'$2b$10$C3.GbBa8CNOQNLgt79NZTe/GY2ikJtk5iCl3xIAoFlb0b3l4WFnjO';
        expect(await app.run(() => Hash.check('secret', bun)), isTrue);
        expect(await app.run(() => Hash.check('wrong', bun)), isFalse);
      },
    );
  });

  group('Hash (argon2id PHC strings, as PHP password_hash writes them)', () {
    test('verifies hashes from libargon2 and Bun', () async {
      // argon2-cffi README (libargon2, the library PHP links against).
      const libargon2 =
          r'$argon2id$v=19$m=65536,t=3,p=4$MIIRqgvgQbgj220jfp0MPA$'
          'YfwJSVjtjSU0zzV/P3S9nnQ/USre2wvJMjfCIjrTQbg';
      // Bun.password.hash('secret', {algorithm: 'argon2id',
      //   memoryCost: 65536, timeCost: 4}): PHP's default m and t.
      const bun =
          r'$argon2id$v=19$m=65536,t=4,p=1$EJUC0V0fkGau7K9h9Zn6gh4xn0bCeG/'
          r'MbvN2/RUspko$JpoHg3XO4FmgNISQcxiYwpGzQQ6kf/exX8TY26ODzBE';
      // bcrypt is the default driver: verify accepts the strong family.
      expect(
        await app.run(
          () => Hash.check('correct horse battery staple', libargon2),
        ),
        isTrue,
      );
      expect(
        await app.run(() => Hash.check('Tr0ub4dor&3', libargon2)),
        isFalse,
      );
      expect(await app.run(() => Hash.check('secret', bun)), isTrue);
      expect(await app.run(() => Hash.needsRehash(bun)), isTrue);
    });
  });

  group('Crypt', () {
    // Built with the OpenSSL CLI exactly like Illuminate\Encryption\Encrypter
    // (aes-256-cbc, base64 value, mac = hmac_sha256(base64(iv) . value)).
    const key = 'base64:AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=';
    const laravelPayload =
        'eyJpdiI6IjhPSFN3N1NsbG9kNGFWcExQQzBlRHc9PSIsInZhbHVlIjoicEpmZnFjcVdDRkVkWGpsRFk3QXVtNjNKYUhKeDJwS2IzUm9OY0c2YjRSQT0iLCJtYWMiOiIzNjA0ZWExZmE1MjZjYWNkMjgzYWRiNmIxZTNlYzgzMDllZWQzMThiMWQxNjUxMDcyYzAwMzA4NmM1ZDAyZWE5IiwidGFnIjoiIn0=';

    test('decrypts a Laravel AES-256-CBC encryptString payload', () async {
      final crypt = Encrypter.fromAppKey(key, cipher: .aes256cbc);
      expect(await crypt.decryptString(laravelPayload), 'hello from laravel');
    });

    test('decrypts a Laravel AES-256-GCM payload (Bun / BoringSSL)', () async {
      // Built like Encrypter::encryptString with cipher aes-256-gcm:
      // 12-byte iv, base64 value and tag, empty mac, PHP-escaped JSON.
      const gcm =
          'eyJpdiI6Im9hS2pwS1dtcDZpcHFxdXMiLCJ2YWx1ZSI6IlRvcnJBNXQxV0IzaEU1'
          'SWNOYkN0QlFmN0NrZ1VLQT09IiwibWFjIjoiIiwidGFnIjoiU2tYZVRnak9kVDRN'
          'V2JxbnQ5NndSUT09In0=';
      for (final cipher in EncryptionCipher.values) {
        final crypt = Encrypter.fromAppKey(key, cipher: cipher);
        expect(await crypt.decryptString(gcm), 'hello from laravel gcm');
      }
    });

    test('rejects a tampered Laravel payload', () async {
      final crypt = Encrypter.fromAppKey(key, cipher: .aes256cbc);
      final json = jsonDecode(
        utf8.decode(base64.decode(laravelPayload)),
      ) as Map<String, Object?>;
      json['mac'] = '0' * 64;
      final tampered = base64.encode(utf8.encode(jsonEncode(json)));
      expect(
        () => crypt.decryptString(tampered),
        throwsA(isA<DecryptException>()),
      );
    });

    test('CBC payloads Laravel can verify: keys, mac and empty tag', () async {
      final crypt = Encrypter.fromAppKey(key, cipher: .aes256cbc);
      final payload = jsonDecode(
        utf8.decode(base64.decode(await crypt.encryptString('hi'))),
      ) as Map<String, Object?>;
      expect(payload.keys, ['iv', 'value', 'mac', 'tag']);
      expect(payload['tag'], '');
      final mac = crypto.Hmac(
        crypto.sha256,
        Encrypter.parseKey(key),
      ).convert(utf8.encode('${payload['iv']}${payload['value']}'));
      expect(payload['mac'], mac.toString());
      expect(base64.decode(payload['iv']! as String), hasLength(16));
    });

    test('zero-config defaults are Laravel\'s: AES-256-CBC and bcrypt '
        '(ADR-024)', () async {
      await app.shutdown();
      // Only the shared APP_KEY: no APP_CIPHER, no HASH_DRIVER.
      (app, client) = await bootConformanceApp(env: {'APP_KEY': key});
      expect(
        await app.run(() => Crypt.decryptString(laravelPayload)),
        'hello from laravel',
      );
      final ours = await app.run(() => Crypt.encryptString('x'));
      final payload =
          jsonDecode(utf8.decode(base64.decode(ours))) as Map<String, Object?>;
      expect(payload['tag'], '', reason: 'CBC payload');
      expect(await app.run(() => Hash.make('secret')), startsWith(r'$2y$'));
      expect(
        await app.run(
          () => Hash.check('password', LaravelContract.bcryptOfPassword),
        ),
        isTrue,
      );
    });

    test('APP_CIPHER=AES-256-GCM opts into GCM', () async {
      await app.shutdown();
      (app, client) = await bootConformanceApp(
        env: {'APP_KEY': key, 'APP_CIPHER': 'AES-256-GCM'},
      );
      final ours = await app.run(() => Crypt.encryptString('x'));
      final payload =
          jsonDecode(utf8.decode(base64.decode(ours))) as Map<String, Object?>;
      expect(payload['mac'], '');
      expect(payload['tag'], isNotEmpty);
    });
  });

  group('schema', () {
    Future<List<Map<String, Object?>>> columns(String table) =>
        app.run(() => DB.select('PRAGMA table_info("$table")'));

    for (final MapEntry(key: table, value: expected)
        in LaravelContract.sharedTables.entries) {
      test('$table has Laravel\'s columns, order and nullability', () async {
        final actual = await columns(table);
        expect(
          [for (final c in actual) c['name']],
          expected.keys.toList(),
          reason: 'columns of $table',
        );
        for (final c in actual) {
          final name = c['name']! as String;
          final nullable = c['notnull'] == 0 && c['pk'] == 0;
          expect(nullable, expected[name], reason: '$table.$name nullable');
        }
      });
    }

    test('indexed columns match Laravel', () async {
      for (final MapEntry(key: table, value: indexed)
          in LaravelContract.sharedIndexes.entries) {
        final indexes = await app.run(
          () => DB.select('PRAGMA index_list("$table")'),
        );
        final covered = <String>{};
        for (final index in indexes) {
          final info = await app.run(
            () => DB.select('PRAGMA index_info("${index['name']}")'),
          );
          if (info.length == 1) {
            covered.add(info.single['name']! as String);
          }
        }
        expect(covered, containsAll(indexed), reason: 'indexes of $table');
      }
    });

    test('framework migrations record Laravel\'s migration names', () async {
      final names = await app.run(
        () async => [
          for (final row in await DB.table('migrations').orderBy('id').get())
            row['migration'],
        ],
      );
      expect(names, containsAll(LaravelContract.sharedMigrationNames.values));
      final batches = await app.run(
        () async => {
          for (final row in await DB.table('migrations').get()) row['batch'],
        },
      );
      expect(batches, {1});
    });
  });
}
