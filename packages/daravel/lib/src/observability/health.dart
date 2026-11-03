import 'dart:async';

import '../cache/cache.dart';
import '../database/database_manager.dart';

/// Outcome of one [HealthCheck].
final class HealthResult {
  /// A passing check, with [meta] details.
  const HealthResult.ok([this.meta = const <String, Object?>{}])
    : ok = true,
      error = null;

  /// A failing check with [error].
  const HealthResult.failed(this.error, [this.meta = const <String, Object?>{}])
    : ok = false;

  /// Whether the check passed.
  final bool ok;

  /// Why it failed.
  final String? error;

  /// Details reported with the result.
  final Map<String, Object?> meta;
}

/// A readiness probe (`/up/ready`).
abstract interface class HealthCheck {
  /// The check's name in `/up/ready`.
  String get name;

  /// Runs the check.
  Future<HealthResult> check();
}

/// Closure-based check (`HealthCheck.of('queue', () async => ...)`).
final class CallbackHealthCheck implements HealthCheck {
  /// A check named [name] running a callback.
  const CallbackHealthCheck(this.name, this._check);

  @override
  final String name;

  final FutureOr<HealthResult> Function() _check;

  @override
  Future<HealthResult> check() async => _check();
}

/// Runs `SELECT 1` on [connection].
final class DatabaseHealthCheck implements HealthCheck {
  /// Checks that [connection] answers a query.
  const DatabaseHealthCheck(this._db, {this.connection});

  final DatabaseManager Function() _db;

  /// The connection checked; the default one when null.
  final String? connection;

  @override
  String get name => connection == null ? 'database' : 'database.$connection';

  @override
  Future<HealthResult> check() async {
    await _db().select('SELECT 1', const <Object?>[], connection);
    return const HealthResult.ok();
  }
}

/// Writes, reads and deletes a probe key.
final class CacheHealthCheck implements HealthCheck {
  /// Checks that [store] can write and read a value.
  const CacheHealthCheck(this._cache, {this.store});

  final CacheManager Function() _cache;

  /// The store checked; the default one when null.
  final String? store;

  @override
  String get name => store == null ? 'cache' : 'cache.$store';

  @override
  Future<HealthResult> check() async {
    final repository = _cache().store(store);
    final key = 'daravel:health:${DateTime.now().microsecondsSinceEpoch}';
    await repository.put(key, 1, ttl: const Duration(seconds: 10));
    final value = await repository.get<int>(key);
    await repository.forget(key);
    return value == 1
        ? const HealthResult.ok()
        : const HealthResult.failed('Cache read-back mismatch.');
  }
}

/// Runs every check with a timeout and builds the `/up/ready` payload.
final class HealthChecker {
  /// Runs [checks], each limited to [timeout].
  HealthChecker(this.checks, {this.timeout = const Duration(seconds: 2)});

  /// The checks run.
  final List<HealthCheck> checks;

  /// How long one check may take.
  final Duration timeout;

  /// `{status: ok|failing, checks: {name: {ok, ms, error?}}}`.
  Future<({bool healthy, Map<String, Object?> body})> run() async {
    final results = await Future.wait(checks.map(_run));
    final healthy = results.every((r) => r.$2['ok'] == true);
    return (
      healthy: healthy,
      body: <String, Object?>{
        'status': healthy ? 'ok' : 'failing',
        'checks': <String, Object?>{for (final r in results) r.$1: r.$2},
      },
    );
  }

  Future<(String, Map<String, Object?>)> _run(HealthCheck check) async {
    final stopwatch = Stopwatch()..start();
    HealthResult result;
    try {
      result = await check.check().timeout(timeout);
    } on TimeoutException {
      result = HealthResult.failed(
        'Timed out after ${timeout.inMilliseconds}ms.',
      );
    } catch (error) {
      result = HealthResult.failed('$error');
    }
    return (
      check.name,
      <String, Object?>{
        'ok': result.ok,
        'ms': stopwatch.elapsedMicroseconds / 1000,
        if (result.error != null) 'error': result.error,
        ...result.meta,
      },
    );
  }
}
