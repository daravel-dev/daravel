import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:bcrypt/bcrypt.dart' as bc;
import 'package:cryptography/cryptography.dart' as cg;

import '../foundation/config.dart';
import '../foundation/env.dart';
import '../foundation/exceptions.dart';

/// Password hashing drivers (ADR-008). Every driver produces a self-describing
/// string so that [HashManager.check] can detect the driver from its prefix.
enum HashDriver {
  /// `$argon2id$v=19$m=65536,t=3,p=1$<salt>$<hash>` (PHC string format).
  argon2id,

  /// `$2y$12$...` — identical to PHP's `password_hash()`, so Laravel and
  /// Daravel can verify each other's hashes.
  bcrypt,

  /// `$pbkdf2-sha256$i=600000$<salt>$<hash>` (legacy / FIPS environments).
  pbkdf2,
}

/// Parsed metadata of a hash string.
final class HashInfo {
  const HashInfo({required this.driver, required this.options});

  /// `null` when the string is not a recognised hash.
  final HashDriver? driver;

  /// Driver-specific cost parameters (`memory`, `time`, `threads`, `rounds`,
  /// `iterations`).
  final Map<String, int> options;

  @override
  String toString() => 'HashInfo($driver, $options)';
}

/// `HASH_DRIVER` / `BCRYPT_ROUNDS` / `ARGON_*` configuration
/// (`config/hashing.php` parity).
final class HashConfig implements ConfigSection {
  const HashConfig({
    this.driver = HashDriver.argon2id,
    this.bcryptRounds = 12,
    this.argonMemory = 65536,
    this.argonTime = 3,
    this.argonThreads = 1,
    this.pbkdf2Iterations = 600000,
    this.verify = true,
  });

  /// Reads the environment; `APP_ENV=testing` lowers every cost so test
  /// suites stay fast (Laravel does the same in `phpunit.xml`).
  factory HashConfig.fromEnv(Env env) {
    final testing = env.string('APP_ENV', 'production') == 'testing';
    final driverName = env.string('HASH_DRIVER', 'argon2id');
    final driver = HashDriver.values.firstWhere(
      (d) => d.name == driverName,
      orElse: () => throw ConfigException(
        'HASH_DRIVER must be one of argon2id, bcrypt, pbkdf2; '
        'got [$driverName].',
      ),
    );
    return HashConfig(
      driver: driver,
      bcryptRounds: env.integer('BCRYPT_ROUNDS', testing ? 4 : 12),
      argonMemory: env.integer('ARGON_MEMORY', testing ? 1024 : 65536),
      argonTime: env.integer('ARGON_TIME', testing ? 1 : 3),
      argonThreads: env.integer('ARGON_THREADS', 1),
      pbkdf2Iterations: env.integer(
        'PBKDF2_ITERATIONS',
        testing ? 1000 : 600000,
      ),
      verify: env.boolean('HASH_VERIFY', true),
    );
  }

  final HashDriver driver;
  final int bcryptRounds;

  /// Argon2id memory in KiB.
  final int argonMemory;
  final int argonTime;
  final int argonThreads;
  final int pbkdf2Iterations;

  /// When true, [HashManager.check] refuses hashes made by a different
  /// driver than the configured one (Laravel 11 `verify` option), which
  /// blocks algorithm-downgrade attacks via injected hashes.
  final bool verify;

  @override
  String get key => 'hashing';

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'driver': driver.name,
    'bcrypt': {'rounds': bcryptRounds},
    'argon': {
      'memory': argonMemory,
      'time': argonTime,
      'threads': argonThreads,
    },
    'pbkdf2': {'iterations': pbkdf2Iterations},
    'verify': verify,
  };
}

/// Creates and verifies password hashes off the event loop.
///
/// Both [make] and [check] run in a compute isolate ([Isolate.run]) so a
/// 100 ms Argon2id derivation never stalls other requests on the HTTP
/// isolate (ADR-004/ADR-008).
final class HashManager {
  HashManager(this.config);

  final HashConfig config;

  /// Hashes [plain] with the configured driver (or [driver]).
  Future<String> make(String plain, {HashDriver? driver}) {
    final target = driver ?? config.driver;
    final cfg = config;
    return Isolate.run(() => _make(plain, target, cfg));
  }

  /// Verifies [plain] against [hashed]; the driver is detected from the
  /// hash prefix. Unknown or malformed hashes never match.
  Future<bool> check(String plain, String hashed) {
    final detected = info(hashed).driver;
    if (detected == null) {
      return Future<bool>.value(false);
    }
    if (config.verify && detected != config.driver) {
      throw HashException(
        'This password does not use the ${config.driver.name} algorithm. '
        'Set HASH_VERIFY=false to accept ${detected.name} hashes.',
      );
    }
    return Isolate.run(() => _check(plain, hashed, detected));
  }

  /// Whether [hashed] was produced by a different driver or cost than the
  /// current configuration (call after a successful login to upgrade).
  bool needsRehash(String hashed) {
    final parsed = info(hashed);
    if (parsed.driver != config.driver) {
      return true;
    }
    final o = parsed.options;
    return switch (config.driver) {
      HashDriver.bcrypt => o['rounds'] != config.bcryptRounds,
      HashDriver.argon2id =>
        o['memory'] != config.argonMemory ||
            o['time'] != config.argonTime ||
            o['threads'] != config.argonThreads,
      HashDriver.pbkdf2 => o['iterations'] != config.pbkdf2Iterations,
    };
  }

  /// Parses the driver and cost parameters out of [hashed].
  HashInfo info(String hashed) {
    if (RegExp(r'^\$2[aby]\$\d{2}\$.{53}$').hasMatch(hashed)) {
      return HashInfo(
        driver: HashDriver.bcrypt,
        options: {'rounds': int.parse(hashed.substring(4, 6))},
      );
    }
    final argon = RegExp(
      r'^\$argon2id\$v=19\$m=(\d+),t=(\d+),p=(\d+)\$[A-Za-z0-9+/]+\$[A-Za-z0-9+/]+$',
    ).firstMatch(hashed);
    if (argon != null) {
      return HashInfo(
        driver: HashDriver.argon2id,
        options: {
          'memory': int.parse(argon[1]!),
          'time': int.parse(argon[2]!),
          'threads': int.parse(argon[3]!),
        },
      );
    }
    final pbkdf2 = RegExp(
      r'^\$pbkdf2-sha256\$i=(\d+)\$[A-Za-z0-9+/]+\$[A-Za-z0-9+/]+$',
    ).firstMatch(hashed);
    if (pbkdf2 != null) {
      return HashInfo(
        driver: HashDriver.pbkdf2,
        options: {'iterations': int.parse(pbkdf2[1]!)},
      );
    }
    return const HashInfo(driver: null, options: {});
  }

  /// Whether [hashed] looks like a hash produced by any known driver.
  bool isHashed(String hashed) => info(hashed).driver != null;

  // ---------------------------------------------------------------------------
  // Isolate workers: static, capturing only sendable values.
  // ---------------------------------------------------------------------------

  static Future<String> _make(
    String plain,
    HashDriver driver,
    HashConfig cfg,
  ) async => switch (driver) {
    HashDriver.bcrypt => bc.BCrypt.hashpw(
      plain,
      bc.BCrypt.gensalt(prefix: r'$2y', logRounds: cfg.bcryptRounds),
    ),
    HashDriver.argon2id => await _argon2(
      plain,
      _randomBytes(16),
      memory: cfg.argonMemory,
      time: cfg.argonTime,
      threads: cfg.argonThreads,
    ),
    HashDriver.pbkdf2 => await _pbkdf2(
      plain,
      _randomBytes(16),
      iterations: cfg.pbkdf2Iterations,
    ),
  };

  static Future<bool> _check(
    String plain,
    String hashed,
    HashDriver driver,
  ) async {
    try {
      switch (driver) {
        case HashDriver.bcrypt:
          return bc.BCrypt.checkpw(plain, hashed);
        case HashDriver.argon2id:
          final parts = hashed.split(r'$');
          final params = <String, int>{
            for (final kv in parts[3].split(','))
              kv.split('=')[0]: int.parse(kv.split('=')[1]),
          };
          final recomputed = await _argon2(
            plain,
            _b64decodeNoPad(parts[4]),
            memory: params['m']!,
            time: params['t']!,
            threads: params['p']!,
          );
          return constantTimeEquals(recomputed, hashed);
        case HashDriver.pbkdf2:
          final parts = hashed.split(r'$');
          final iterations = int.parse(parts[2].substring(2));
          final recomputed = await _pbkdf2(
            plain,
            _b64decodeNoPad(parts[3]),
            iterations: iterations,
          );
          return constantTimeEquals(recomputed, hashed);
      }
    } on FormatException {
      return false;
    } on RangeError {
      return false;
    } on ArgumentError {
      return false;
    }
  }

  static Future<String> _argon2(
    String plain,
    List<int> salt, {
    required int memory,
    required int time,
    required int threads,
  }) async {
    final algorithm = cg.Argon2id(
      parallelism: threads,
      memory: memory,
      iterations: time,
      hashLength: 32,
    );
    final key = await algorithm.deriveKeyFromPassword(
      password: plain,
      nonce: salt,
    );
    final bytes = await key.extractBytes();
    return r'$argon2id$v=19$m='
        '$memory,t=$time,p=$threads'
        r'$'
        '${_b64encodeNoPad(salt)}'
        r'$'
        '${_b64encodeNoPad(bytes)}';
  }

  static Future<String> _pbkdf2(
    String plain,
    List<int> salt, {
    required int iterations,
  }) async {
    final algorithm = cg.Pbkdf2.hmacSha256(iterations: iterations, bits: 256);
    final key = await algorithm.deriveKeyFromPassword(
      password: plain,
      nonce: salt,
    );
    final bytes = await key.extractBytes();
    return r'$pbkdf2-sha256$i='
        '$iterations'
        r'$'
        '${_b64encodeNoPad(salt)}'
        r'$'
        '${_b64encodeNoPad(bytes)}';
  }

  static Uint8List _randomBytes(int length) {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(length, (_) => random.nextInt(256)),
    );
  }

  static String _b64encodeNoPad(List<int> bytes) =>
      base64.encode(bytes).replaceAll('=', '');

  static Uint8List _b64decodeNoPad(String value) =>
      base64.decode(value.padRight((value.length + 3) ~/ 4 * 4, '='));
}

/// Raised for driver mismatches and malformed hashes.
final class HashException extends DaravelException {
  const HashException(super.message);
}

/// Compares two strings without leaking their common-prefix length through
/// timing (BLUEPRINT_V2 §7.6.5).
bool constantTimeEquals(String a, String b) =>
    constantTimeBytesEquals(utf8.encode(a), utf8.encode(b));

/// Byte-wise constant-time comparison.
bool constantTimeBytesEquals(List<int> x, List<int> y) {
  var diff = x.length ^ y.length;
  for (var i = 0; i < x.length && i < y.length; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}

/// Cryptographically random token of [length] URL-safe alphanumeric chars
/// (Laravel `Str::random`).
String secureRandomString(int length) {
  const alphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';
  final random = Random.secure();
  return String.fromCharCodes(
    List<int>.generate(
      length,
      (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length)),
    ),
  );
}
