import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  HashConfig config(HashDriver driver, {bool verify = true}) => HashConfig(
    driver: driver,
    bcryptRounds: 4,
    argonMemory: 1024,
    argonTime: 1,
    pbkdf2Iterations: 1000,
    verify: verify,
  );

  for (final driver in HashDriver.values) {
    test('${driver.name}: make/check/info/needsRehash', () async {
      final hash = HashManager(config(driver));
      final hashed = await hash.make('secret-123');
      expect(hashed, isNot(contains('secret-123')));
      expect(hash.info(hashed).driver, driver);
      expect(hash.isHashed(hashed), isTrue);
      expect(await hash.check('secret-123', hashed), isTrue);
      expect(await hash.check('wrong', hashed), isFalse);
      expect(hash.needsRehash(hashed), isFalse);
      // Two hashes of the same input differ (random salt).
      expect(await hash.make('secret-123'), isNot(hashed));
    });
  }

  test('PHC / bcrypt prefixes are parsed with their cost parameters', () {
    final hash = HashManager(config(HashDriver.argon2id));
    expect(
      hash
          .info(
            r'$argon2id$v=19$m=65536,t=3,p=1$c2FsdHNhbHRzYWx0c2FsdA$aGFzaGhhc2hoYXNoaGFzaA',
          )
          .options,
      {'memory': 65536, 'time': 3, 'threads': 1},
    );
    expect(
      hash
          .info(r'$2y$12$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi')
          .options,
      {'rounds': 12},
    );
    expect(hash.info('plain:password').driver, isNull);
    expect(hash.isHashed('nope'), isFalse);
  });

  test('verifies a hash produced by Laravel (bcrypt \$2y\$)', () async {
    const laravel =
        r'$2y$10$92IXUNpkjO0rOQ5byMi.Ye4oKoEa3Ro9llC/.og/at2.uheWG/igi';
    final hash = HashManager(config(HashDriver.bcrypt));
    expect(await hash.check('password', laravel), isTrue);
    expect(await hash.check('Password', laravel), isFalse);
    // Cost 10 differs from configured 4 → upgrade on next login.
    expect(hash.needsRehash(laravel), isTrue);
  });

  test('needsRehash flags a driver change', () async {
    final bcrypt = HashManager(config(HashDriver.bcrypt));
    final argon = HashManager(config(HashDriver.argon2id, verify: false));
    final hashed = await bcrypt.make('pw');
    expect(argon.needsRehash(hashed), isTrue);
    expect(await argon.check('pw', hashed), isTrue);
  });

  test(
    'verify=true refuses foreign algorithms (downgrade protection)',
    () async {
      final bcrypt = HashManager(config(HashDriver.bcrypt));
      final argon = HashManager(config(HashDriver.argon2id));
      final hashed = await bcrypt.make('pw');
      expect(() => argon.check('pw', hashed), throwsA(isA<HashException>()));
    },
  );

  test('unknown strings never verify', () async {
    final hash = HashManager(config(HashDriver.argon2id));
    expect(await hash.check('pw', 'plain:pw'), isFalse);
    expect(await hash.check('pw', ''), isFalse);
    expect(await hash.check('pw', r'$argon2id$v=19$m=1,t=1,p=1$x$y'), isFalse);
  });

  test('fromEnv lowers cost in testing and validates the driver', () {
    final testing = HashConfig.fromEnv(
      Env.fromMap({'APP_ENV': 'testing', 'HASH_DRIVER': 'bcrypt'}),
    );
    expect(testing.driver, HashDriver.bcrypt);
    expect(testing.bcryptRounds, 4);
    final production = HashConfig.fromEnv(
      Env.fromMap({'APP_ENV': 'production'}),
    );
    expect(production.argonMemory, 65536);
    expect(
      () => HashConfig.fromEnv(Env.fromMap({'HASH_DRIVER': 'md5'})),
      throwsA(isA<ConfigException>()),
    );
  });

  test('constant time comparison and random strings', () {
    expect(constantTimeEquals('abc', 'abc'), isTrue);
    expect(constantTimeEquals('abc', 'abd'), isFalse);
    expect(constantTimeEquals('abc', 'abcd'), isFalse);
    final token = secureRandomString(40);
    expect(token, hasLength(40));
    expect(token, matches(RegExp(r'^[A-Za-z0-9]+$')));
    expect(secureRandomString(40), isNot(token));
  });
}
