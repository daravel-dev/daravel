import 'dart:async';
import 'dart:math';

import 'package:daravel/daravel.dart';

import 'client.dart';

/// A limiter gave up waiting (Laravel's `LimiterTimeoutException`).
final class LimiterTimeoutException extends DaravelException {
  const LimiterTimeoutException(String name)
    : super('Timed out waiting for the [$name] limiter.');
}

/// Laravel's `DurationLimiter` with its script and key, so a Laravel
/// application and a Daravel one count against the same limit: at most
/// [maxLocks] acquisitions per [decay], in a hash at [name].
final class RedisDurationLimiter {
  RedisDurationLimiter(
    this.client,
    this.name, {
    required this.maxLocks,
    required this.decay,
  });

  final RedisClient client;
  final String name;
  final int maxLocks;
  final Duration decay;

  /// When the current window ends (unix seconds), after [acquire] or
  /// [tooManyAttempts].
  int decaysAt = 0;

  /// Acquisitions left in the current window.
  int remaining = 0;

  static final RedisScript _acquire = RedisScript('''
local function reset()
    redis.call('HMSET', KEYS[1], 'start', ARGV[2], 'end', ARGV[2] + ARGV[3], 'count', 1)
    return redis.call('EXPIRE', KEYS[1], ARGV[3] * 2)
end
if redis.call('EXISTS', KEYS[1]) == 0 then
    return {reset(), ARGV[2] + ARGV[3], ARGV[4] - 1}
end
if ARGV[1] >= redis.call('HGET', KEYS[1], 'start') and ARGV[1] <= redis.call('HGET', KEYS[1], 'end') then
    return {
        tonumber(redis.call('HINCRBY', KEYS[1], 'count', 1)) <= tonumber(ARGV[4]),
        redis.call('HGET', KEYS[1], 'end'),
        ARGV[4] - redis.call('HGET', KEYS[1], 'count')
    }
end
return {reset(), ARGV[2] + ARGV[3], ARGV[4] - 1}''');

  static final RedisScript _tooMany = RedisScript('''
if redis.call('EXISTS', KEYS[1]) == 0 then
    return {0, ARGV[2] + ARGV[3]}
end
if ARGV[1] >= redis.call('HGET', KEYS[1], 'start') and ARGV[1] <= redis.call('HGET', KEYS[1], 'end') then
    return {
        redis.call('HGET', KEYS[1], 'end'),
        ARGV[4] - redis.call('HGET', KEYS[1], 'count')
    }
end
return {0, ARGV[2] + ARGV[3]}''');

  /// `microtime(true)` and `time()` of now, as Laravel passes them.
  List<Object> get _args {
    final ms = Clock.now().toUtc().millisecondsSinceEpoch;
    return [
      (ms / 1000).toStringAsFixed(4),
      ms ~/ 1000,
      decay.inSeconds,
      maxLocks,
    ];
  }

  static int _int(Object? value) => switch (value) {
    final int number => number,
    final String text => int.tryParse(text) ?? 0,
    _ => 0,
  };

  /// Takes one acquisition; whether there was one left.
  Future<bool> acquire() async {
    final reply =
        (await client.eval(_acquire, keys: [name], args: _args))! as List;
    decaysAt = _int(reply[1]);
    remaining = max(0, _int(reply[2]));
    return reply[0] != null && reply[0] != 0;
  }

  /// Whether none is left, without taking one.
  Future<bool> tooManyAttempts() async {
    final reply =
        (await client.eval(_tooMany, keys: [name], args: _args))! as List;
    decaysAt = _int(reply[0]);
    remaining = _int(reply[1]);
    return remaining <= 0;
  }

  Future<void> clear() => client.del([name]);

  /// Acquires, retrying every [sleep] for up to [timeout], then runs
  /// [callback]; [LimiterTimeoutException] when none came free.
  Future<T> block<T>(
    Duration timeout,
    FutureOr<T> Function() callback, {
    Duration sleep = const Duration(milliseconds: 750),
  }) async {
    final waited = Stopwatch()..start();
    while (!await acquire()) {
      if (waited.elapsed >= timeout) {
        throw LimiterTimeoutException(name);
      }
      await Future<void>.delayed(sleep);
    }
    return callback();
  }
}

/// Laravel's `ConcurrencyLimiter`: at most [maxLocks] holders at a time,
/// each slot a key `<name><n>` held for [releaseAfter] at most. In a
/// cluster the slots need one hash slot: give [name] a hash tag
/// (`{imports}`).
final class RedisConcurrencyLimiter {
  RedisConcurrencyLimiter(
    this.client,
    this.name, {
    required this.maxLocks,
    this.releaseAfter = const Duration(seconds: 60),
  });

  final RedisClient client;
  final String name;
  final int maxLocks;
  final Duration releaseAfter;

  static final RedisScript _lock = RedisScript('''
for index, value in pairs(redis.call('mget', unpack(KEYS))) do
    if not value then
        redis.call('set', KEYS[index], ARGV[3], "EX", ARGV[2])
        return ARGV[1]..index
    end
end''');

  static final RedisScript _release = RedisScript('''
if redis.call('get', KEYS[1]) == ARGV[1]
then
    return redis.call('del', KEYS[1])
else
    return 0
end''');

  static final Random _random = Random.secure();

  /// Takes a free slot for [id]: its key, or null when all are held.
  Future<String?> acquire(String id) async => await client.eval(
    _lock,
    keys: [for (var i = 1; i <= maxLocks; i++) '$name$i'],
    args: [name, max(1, releaseAfter.inSeconds), id],
  ) as String?;

  Future<void> release(String slot, String id) async {
    await client.eval(_release, keys: [slot], args: [id]);
  }

  /// Takes a slot, retrying every [sleep] for up to [timeout], runs
  /// [callback] and frees the slot, even when [callback] throws.
  Future<T> block<T>(
    Duration timeout,
    FutureOr<T> Function() callback, {
    Duration sleep = const Duration(milliseconds: 250),
  }) async {
    const letters =
        'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final id = String.fromCharCodes([
      for (var i = 0; i < 20; i++)
        letters.codeUnitAt(_random.nextInt(letters.length)),
    ]);
    final waited = Stopwatch()..start();
    String? slot;
    while ((slot = await acquire(id)) == null) {
      if (waited.elapsed >= timeout) {
        throw LimiterTimeoutException(name);
      }
      await Future<void>.delayed(sleep);
    }
    try {
      return await callback();
    } finally {
      await release(slot!, id);
    }
  }
}

/// `Redis.throttle('key').allow(10).every(...).then(...)` (Laravel's
/// `DurationLimiterBuilder`).
final class RedisThrottleBuilder {
  RedisThrottleBuilder(this.client, this.name);

  final RedisClient client;
  final String name;
  int? _maxLocks;
  Duration _decay = const Duration(seconds: 60);
  Duration _timeout = const Duration(seconds: 3);
  Duration _sleep = const Duration(milliseconds: 750);

  /// Acquisitions per [every].
  RedisThrottleBuilder allow(int maxLocks) {
    _maxLocks = maxLocks;
    return this;
  }

  RedisThrottleBuilder every(Duration decay) {
    _decay = decay;
    return this;
  }

  /// How long [then] waits for one (3 seconds by default).
  RedisThrottleBuilder block(Duration timeout) {
    _timeout = timeout;
    return this;
  }

  RedisThrottleBuilder sleep(Duration sleep) {
    _sleep = sleep;
    return this;
  }

  /// Runs [callback] once allowed; on timeout [failure], or throws
  /// [LimiterTimeoutException].
  Future<T> then<T>(
    FutureOr<T> Function() callback, [
    FutureOr<T> Function(LimiterTimeoutException error)? failure,
  ]) async {
    final limiter = RedisDurationLimiter(
      client,
      name,
      maxLocks:
          _maxLocks ??
          (throw StateError('Redis.throttle($name) needs allow(n).')),
      decay: _decay,
    );
    try {
      return await limiter.block(_timeout, callback, sleep: _sleep);
    } on LimiterTimeoutException catch (error) {
      if (failure == null) {
        rethrow;
      }
      return failure(error);
    }
  }
}

/// `Redis.funnel('key').limit(3).then(...)` (Laravel's
/// `ConcurrencyLimiterBuilder`).
final class RedisFunnelBuilder {
  RedisFunnelBuilder(this.client, this.name);

  final RedisClient client;
  final String name;
  int? _maxLocks;
  Duration _releaseAfter = const Duration(seconds: 60);
  Duration _timeout = const Duration(seconds: 3);
  Duration _sleep = const Duration(milliseconds: 250);

  /// Holders at a time.
  RedisFunnelBuilder limit(int maxLocks) {
    _maxLocks = maxLocks;
    return this;
  }

  /// When a holder's slot frees itself, should it never release it.
  RedisFunnelBuilder releaseAfter(Duration releaseAfter) {
    _releaseAfter = releaseAfter;
    return this;
  }

  RedisFunnelBuilder block(Duration timeout) {
    _timeout = timeout;
    return this;
  }

  RedisFunnelBuilder sleep(Duration sleep) {
    _sleep = sleep;
    return this;
  }

  Future<T> then<T>(
    FutureOr<T> Function() callback, [
    FutureOr<T> Function(LimiterTimeoutException error)? failure,
  ]) async {
    final limiter = RedisConcurrencyLimiter(
      client,
      name,
      maxLocks:
          _maxLocks ??
          (throw StateError('Redis.funnel($name) needs limit(n).')),
      releaseAfter: _releaseAfter,
    );
    try {
      return await limiter.block(_timeout, callback, sleep: _sleep);
    } on LimiterTimeoutException catch (error) {
      if (failure == null) {
        rethrow;
      }
      return failure(error);
    }
  }
}
