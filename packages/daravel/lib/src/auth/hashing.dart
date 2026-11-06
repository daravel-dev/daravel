import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' as cg;
import 'package:cryptography/dart.dart' as cgd;

import '../concurrency/compute_pool.dart';
import '../foundation/config.dart';
import 'bcrypt.dart';
import '../foundation/env.dart';
import '../foundation/exceptions.dart';
import '../http/http_exceptions.dart';

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
  /// A hash made with [driver] and [options].
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
  /// Hash settings; usually from `.env` (`HASH_DRIVER`, `BCRYPT_ROUNDS`...).
  const HashConfig({
    this.driver = .bcrypt,
    this.bcryptRounds = 12,
    this.argonMemory = 65536,
    this.argonTime = 3,
    this.argonThreads = 1,
    this.pbkdf2Iterations = 600000,
    this.verify = true,
    this.concurrency,
    this.maxQueue = defaultMaxQueue,
    this.queueTimeout = defaultQueueTimeout,
  });

  /// Hashes waiting for a busy hashing isolate before more are refused.
  static const int defaultMaxQueue = 1024;

  /// How long a hash waits for a hashing isolate before it is refused.
  static const Duration defaultQueueTimeout = Duration(seconds: 30);

  /// Reads the environment; `APP_ENV=testing` lowers every cost so test
  /// suites stay fast (Laravel does the same in `phpunit.xml`).
  factory HashConfig.fromEnv(Env env) {
    final testing = env.string('APP_ENV', 'production') == 'testing';
    // Laravel's default driver (ADR-024), so a shared users table works.
    final driverName = env.string('HASH_DRIVER', 'bcrypt');
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
      concurrency: switch (env.integer('HASH_CONCURRENCY', 0)) {
        < 0 => throw const ConfigException(
          'HASH_CONCURRENCY must be a positive number of isolates, or 0 for '
          'one per processor.',
        ),
        0 => null,
        final int n => n,
      },
      maxQueue: switch (env.integer('HASH_QUEUE', defaultMaxQueue)) {
        < 0 => throw const ConfigException(
          'HASH_QUEUE must be a positive number of waiting hashes, or 0 for '
          'no limit.',
        ),
        0 => null,
        final int n => n,
      },
      queueTimeout: env.duration('HASH_QUEUE_TIMEOUT', defaultQueueTimeout),
    );
  }

  /// The driver new hashes use (`bcrypt`).
  final HashDriver driver;

  /// The bcrypt cost (12).
  final int bcryptRounds;

  /// Argon2id memory in KiB.
  final int argonMemory;

  /// The argon2id iterations.
  final int argonTime;

  /// The argon2id parallelism.
  final int argonThreads;

  /// The PBKDF2 iterations.
  final int pbkdf2Iterations;

  /// When true, [HashManager.check] refuses hashes of a different driver
  /// unless they belong to the strong family ({bcrypt, argon2id}, ADR-024):
  /// legacy or weak formats (pbkdf2) cannot be injected as a downgrade, while
  /// a bcrypt ⇄ argon2id switch still verifies old hashes so
  /// `rehashPasswordIfRequired` can upgrade them at login.
  final bool verify;

  /// How many hashes run at once, each in its own warm isolate
  /// (`HASH_CONCURRENCY`); null means one per processor. A login burst
  /// waits for these isolates instead of spawning one per attempt, which
  /// with argon2id (64 MiB each) could exhaust memory.
  final int? concurrency;

  /// The most hashes waiting for an isolate (`HASH_QUEUE`, 1024); null
  /// means no limit. Past it [HashManager.make] and [HashManager.check]
  /// throw [HashingSaturatedException] at once.
  final int? maxQueue;

  /// How long a hash waits for an isolate before [HashingSaturatedException]
  /// (`HASH_QUEUE_TIMEOUT`, 30 s).
  final Duration queueTimeout;

  /// [concurrency], or the number of processors.
  int get effectiveConcurrency => concurrency ?? Platform.numberOfProcessors;

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

/// Drivers whose hashes [HashManager.check] accepts across a driver switch
/// even with `verify` enabled (ADR-024).
const Set<HashDriver> strongDrivers = {HashDriver.bcrypt, HashDriver.argon2id};

/// Creates and verifies password hashes off the event loop.
///
/// Both [make] and [check] run in warm compute isolates, so a 100 ms
/// Argon2id derivation never stalls other requests on the HTTP isolate
/// (ADR-004/ADR-008). At most [HashConfig.concurrency] run at once; others
/// wait, up to [HashConfig.maxQueue] of them for [HashConfig.queueTimeout],
/// and past that fail with [HashingSaturatedException] (a `503`), so a
/// login burst queues instead of spawning an isolate per attempt.
final class HashManager {
  /// A manager hashing with [config].
  HashManager(this.config);

  /// The hash settings.
  final HashConfig config;

  late final ComputePool _pool = ComputePool(
    () => config.effectiveConcurrency,
    maxQueue: () => config.maxQueue,
  );

  /// Hashing isolates alive right now.
  int get isolates => _pool.size;

  /// Hashes waiting for an isolate right now.
  int get waiting => _pool.waiting;

  /// Hashes [plain] with the configured driver (or [driver]).
  Future<String> make(String plain, {HashDriver? driver}) =>
      _run(_makeTask(plain, driver ?? config.driver, config));

  /// Stops the hashing isolates (`Application.shutdown`); the next hash
  /// starts them again.
  Future<void> close() => _pool.shutdown();

  Future<T> _run<T>(FutureOr<T> Function() task) async {
    try {
      return await _pool.run(task, queueTimeout: config.queueTimeout);
    } on ComputePoolSaturatedError catch (error) {
      throw HashingSaturatedException(error.message);
    }
  }

  // Built in static functions, so a task captures its arguments alone.
  static FutureOr<String> Function() _makeTask(
    String plain,
    HashDriver driver,
    HashConfig cfg,
  ) =>
      () => _make(plain, driver, cfg);

  static FutureOr<bool> Function() _checkTask(
    String plain,
    String hashed,
    HashDriver driver,
  ) =>
      () => _check(plain, hashed, driver);

  /// Verifies [plain] against [hashed]; the driver is detected from the
  /// hash prefix. Unknown or malformed hashes never match.
  Future<bool> check(String plain, String hashed) {
    final detected = info(hashed).driver;
    if (detected == null) {
      return Future<bool>.value(false);
    }
    if (config.verify &&
        detected != config.driver &&
        !strongDrivers.contains(detected)) {
      throw HashException(
        'This password does not use the ${config.driver.name} algorithm. '
        'Set HASH_VERIFY=false to accept ${detected.name} hashes.',
      );
    }
    return _run(_checkTask(plain, hashed, detected));
  }

  Future<String>? _dummy;

  /// Spends the same time as a real [check] of [plain], for when no user
  /// matched the credentials, so response timing does not reveal which
  /// accounts exist (BLUEPRINT_V2 §9.2 item 9). Completes normally, whatever
  /// [plain] is, unless hashing itself fails ([HashingSaturatedException]);
  /// a failed dummy hash is made again by the next call.
  Future<void> checkAgainstDummy(String plain) async {
    final dummy = _dummy ??= make('daravel-timing-equalizer');
    final String hashed;
    try {
      hashed = await dummy;
    } catch (_) {
      if (identical(_dummy, dummy)) {
        _dummy = null;
      }
      rethrow;
    }
    await check(plain, hashed);
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
      .bcrypt => o['rounds'] != config.bcryptRounds,
      .argon2id =>
        o['memory'] != config.argonMemory ||
            o['time'] != config.argonTime ||
            o['threads'] != config.argonThreads,
      .pbkdf2 => o['iterations'] != config.pbkdf2Iterations,
    };
  }

  /// Parses the driver and cost parameters out of [hashed].
  HashInfo info(String hashed) {
    if (RegExp(r'^\$2[aby]\$\d{2}\$.{53}$').hasMatch(hashed)) {
      return HashInfo(
        driver: .bcrypt,
        options: {'rounds': int.parse(hashed.substring(4, 6))},
      );
    }
    final argon = RegExp(
      r'^\$argon2id\$v=19\$m=(\d+),t=(\d+),p=(\d+)\$[A-Za-z0-9+/]+\$[A-Za-z0-9+/]+$',
    ).firstMatch(hashed);
    if (argon != null) {
      return HashInfo(
        driver: .argon2id,
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
        driver: .pbkdf2,
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
    .bcrypt => Bcrypt.hash(plain, cost: cfg.bcryptRounds),
    .argon2id => await _argon2(
      plain,
      _randomBytes(16),
      memory: cfg.argonMemory,
      time: cfg.argonTime,
      threads: cfg.argonThreads,
    ),
    .pbkdf2 => await _pbkdf2(
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
        case .bcrypt:
          return Bcrypt.verify(plain, hashed);
        case .argon2id:
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
        case .pbkdf2:
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
    // Lanes run in this isolate (maxIsolates: 0): hashing already runs in a
    // compute isolate, and the default helper isolates (one per lane,
    // sharing raw memory) could stall indefinitely when many isolates are
    // busy.
    final algorithm = cgd.DartArgon2id(
      parallelism: threads,
      memory: memory,
      iterations: time,
      hashLength: 32,
      maxIsolates: 0,
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
  /// A hash that cannot be made or read.
  const HashException(super.message);
}

/// Every hashing isolate is busy and the wait queue is full, or a hash
/// waited longer than `HASH_QUEUE_TIMEOUT` ([HashConfig]): answered as
/// `503 Service Unavailable` with `Retry-After: 1`.
final class HashingSaturatedException extends HttpException {
  /// Hashing refused a password; [reason] says why (logged, not sent).
  const HashingSaturatedException(this.reason)
    : super(
        503,
        'Service Unavailable',
        headers: const <String, String>{'Retry-After': '1'},
      );

  /// Why the hash was refused.
  final String reason;

  @override
  String toString() => 'HashingSaturatedException: $reason';
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

/// PHP `hash('crc32b', $data)`: CRC-32 (IEEE 802.3, as zlib) as 8 lowercase
/// hex digits. Sanctum appends it to token secrets so leaked tokens can be
/// recognised by secret scanners.
String crc32b(List<int> bytes) {
  var crc = 0xFFFFFFFF;
  for (final byte in bytes) {
    crc ^= byte;
    for (var bit = 0; bit < 8; bit++) {
      crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xEDB88320 : crc >>> 1;
    }
  }
  return ((crc ^ 0xFFFFFFFF) & 0xFFFFFFFF).toRadixString(16).padLeft(8, '0');
}
