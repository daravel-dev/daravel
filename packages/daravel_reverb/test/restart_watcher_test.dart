import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_reverb/daravel_reverb.dart';
import 'package:test/test.dart';

Future<Application> booted() async {
  final app = Application.configure(basePath: Directory.systemTemp.path)
      .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
      .withLogLevel(LogLevel.critical)
      .create();
  await app.boot();
  addTearDown(app.shutdown);
  return app;
}

/// Lets the watcher's polls run (a few milliseconds each).
Future<void> polls([int count = 10]) async {
  for (var i = 0; i < count; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  late MemoryStore signals;

  setUp(() => signals = MemoryStore());

  Future<(Application, ReverbRestartWatcher)> watching() async {
    final app = await booted();
    final watcher = ReverbRestartWatcher(
      app,
      signals,
      poll: const Duration(milliseconds: 2),
      spread: Duration.zero,
    )..start();
    addTearDown(watcher.stop);
    return (app, watcher);
  }

  Future<void> request(Object value) => signals.put(reverbRestartKey, value);

  test('a request already there at the start, even "from the future", is '
      'not one', () async {
    // Another machine's clock, ahead of this one.
    await request(
      DateTime.now().add(const Duration(days: 1)).millisecondsSinceEpoch,
    );
    final (app, watcher) = await watching();
    await polls();
    expect(app.restartRequested, isFalse);
    expect(watcher.watching, isTrue);
  });

  test('a changed value restarts once; the worker spawned again does not '
      'restart again', () async {
    await request(1);
    final (app, watcher) = await watching();
    await polls();
    expect(app.restartRequested, isFalse);

    // An earlier time than the one there: still a new request.
    await request(0);
    await polls();
    expect(app.restartRequested, isTrue);
    expect(watcher.watching, isFalse);

    final (respawned, again) = await watching();
    await polls();
    expect(respawned.restartRequested, isFalse);
    expect(again.watching, isTrue);
  });

  test('a key never set, then set, is a request', () async {
    final (app, _) = await watching();
    await polls();
    expect(app.restartRequested, isFalse);
    await request(DateTime.now().millisecondsSinceEpoch);
    await polls();
    expect(app.restartRequested, isTrue);
  });

  test('a store down at the start: the value already there is no request '
      'once it answers; a new one is', () async {
    await request(1);
    final flaky = _Flaky(signals, failures: 5);
    final app = await booted();
    final watcher = ReverbRestartWatcher(
      app,
      flaky,
      poll: const Duration(milliseconds: 2),
      spread: Duration.zero,
    )..start();
    addTearDown(watcher.stop);
    await polls();
    expect(flaky.failures, 0, reason: 'the store answers again');
    expect(app.restartRequested, isFalse);
    await request(2);
    await polls();
    expect(app.restartRequested, isTrue);
  });
}

/// [inner], whose first [failures] reads throw (a store down for a moment).
final class _Flaky implements CacheStore {
  _Flaky(this.inner, {required this.failures});

  final CacheStore inner;
  int failures;

  @override
  StateScope get scope => inner.scope;

  @override
  Future<Object?> get(String key) {
    if (failures > 0) {
      failures--;
      throw StateError('store down');
    }
    return inner.get(key);
  }

  @override
  Future<Map<String, Object?>> many(List<String> keys) => inner.many(keys);

  @override
  Future<void> put(String key, Object? value, {Duration? ttl}) =>
      inner.put(key, value, ttl: ttl);

  @override
  Future<void> putMany(Map<String, Object?> values, {Duration? ttl}) =>
      inner.putMany(values, ttl: ttl);

  @override
  Future<bool> add(String key, Object? value, {Duration? ttl}) =>
      inner.add(key, value, ttl: ttl);

  @override
  Future<int> increment(String key, [int by = 1]) => inner.increment(key, by);

  @override
  Future<int> decrement(String key, [int by = 1]) => inner.decrement(key, by);

  @override
  Future<void> forever(String key, Object? value) => inner.forever(key, value);

  @override
  Future<bool> forget(String key) => inner.forget(key);

  @override
  Future<void> flush() => inner.flush();

  @override
  Future<bool> acquireLock(String name, String owner, Duration ttl) =>
      inner.acquireLock(name, owner, ttl);

  @override
  Future<bool> releaseLock(String name, String owner) =>
      inner.releaseLock(name, owner);

  @override
  Future<void> forceReleaseLock(String name) => inner.forceReleaseLock(name);

  @override
  Future<String?> lockOwner(String name) => inner.lockOwner(name);
}
