import 'dart:async';
import 'dart:math';
import '../foundation/clock.dart';

import 'package:path/path.dart' as p;

import '../database/database_manager.dart';
import '../database/schema/migration.dart';
import '../database/schema/schema_builder.dart';
import '../foundation/config.dart';
import '../foundation/env.dart';
import '../foundation/exceptions.dart';
import '../server/coordinator.dart';
import 'stores.dart';

/// Backing store contract (BLUEPRINT_V2 §7.7). Values must be
/// JSON-serializable for the file/database stores.
abstract interface class CacheStore {
  StateScope get scope;

  Future<Object?> get(String key);

  Future<Map<String, Object?>> many(List<String> keys);

  /// Stores [value] for [ttl] (`null` = forever).
  Future<void> put(String key, Object? value, {Duration? ttl});

  Future<void> putMany(Map<String, Object?> values, {Duration? ttl});

  /// Stores only when [key] is absent (atomic per store scope).
  Future<bool> add(String key, Object? value, {Duration? ttl});

  Future<int> increment(String key, [int by = 1]);

  Future<int> decrement(String key, [int by = 1]);

  Future<void> forever(String key, Object? value);

  Future<bool> forget(String key);

  Future<void> flush();

  Future<bool> acquireLock(String name, String owner, Duration ttl);

  Future<bool> releaseLock(String name, String owner);

  Future<void> forceReleaseLock(String name);

  Future<String?> lockOwner(String name);
}

/// Raised by [Lock.block] when the lock cannot be obtained in time.
final class LockTimeoutException extends DaravelException {
  LockTimeoutException(String name, Duration timeout)
    : super(
        'Could not acquire lock [$name] within ${timeout.inMilliseconds}ms.',
      );
}

/// An atomic lock (Laravel `Cache::lock`). Semantics are **fail-closed**:
/// a coordinator error surfaces as an exception instead of a false "got it".
final class Lock {
  Lock(
    this._store,
    this.name, {
    this.ttl = const Duration(seconds: 10),
    String? owner,
  }) : owner = owner ?? _randomOwner();

  final CacheStore _store;
  final String name;
  final Duration ttl;
  final String owner;

  /// Tries once; with [callback], runs it while holding the lock and
  /// releases afterwards.
  Future<bool> get([FutureOr<void> Function()? callback]) async {
    if (!await acquire()) {
      return false;
    }
    if (callback == null) {
      return true;
    }
    try {
      await callback();
    } finally {
      await release();
    }
    return true;
  }

  /// Waits up to [timeout] (polling every [interval]) then runs [callback].
  Future<T> block<T>(
    Duration timeout,
    FutureOr<T> Function() callback, {
    Duration interval = const Duration(milliseconds: 100),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!await acquire()) {
      if (!DateTime.now().isBefore(deadline)) {
        throw LockTimeoutException(name, timeout);
      }
      await Future<void>.delayed(interval);
    }
    try {
      return await callback();
    } finally {
      await release();
    }
  }

  Future<bool> acquire() => _store.acquireLock(name, owner, ttl);

  /// Releases only when this instance owns the lock.
  Future<bool> release() => _store.releaseLock(name, owner);

  Future<void> forceRelease() => _store.forceReleaseLock(name);

  Future<String?> currentOwner() => _store.lockOwner(name);

  static String _randomOwner() {
    const alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
    final random = Random.secure();
    return String.fromCharCodes(
      List<int>.generate(
        16,
        (_) => alphabet.codeUnitAt(random.nextInt(alphabet.length)),
      ),
    );
  }
}

/// `CACHE_*` configuration (`config/cache.php` parity).
final class CacheConfig implements ConfigSection {
  const CacheConfig({
    this.defaultStore = 'memory',
    this.prefix = 'daravel_cache_',
    this.path = 'storage/framework/cache',
    this.table = 'cache',
    this.lockTable = 'cache_locks',
    this.maxEntries = 10000,
  });

  factory CacheConfig.fromEnv(Env env) {
    final appName = env.string('APP_NAME', 'daravel');
    return CacheConfig(
      defaultStore: env.string('CACHE_STORE', 'memory'),
      prefix: env.string(
        'CACHE_PREFIX',
        '${appName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}_cache_',
      ),
      path: env.string('CACHE_PATH', 'storage/framework/cache'),
      table: env.string('CACHE_TABLE', 'cache'),
      lockTable: env.string('CACHE_LOCK_TABLE', 'cache_locks'),
      maxEntries: env.integer('CACHE_MAX_ENTRIES', 10000),
    );
  }

  /// `memory` | `process` | `file` | `database`.
  final String defaultStore;
  final String prefix;
  final String path;
  final String table;
  final String lockTable;
  final int maxEntries;

  @override
  String get key => 'cache';

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'default': defaultStore,
    'prefix': prefix,
    'stores': {
      'memory': {'driver': 'memory', 'max_entries': maxEntries},
      'process': {'driver': 'process'},
      'file': {'driver': 'file', 'path': path},
      'database': {
        'driver': 'database',
        'table': table,
        'lock_table': lockTable,
      },
    },
  };
}

/// A store wrapped with a key prefix and the high-level API
/// (`remember`, `flexible`, `lock`, …).
final class CacheRepository {
  CacheRepository(this.store, {this.prefix = '', this.lockStore});

  final CacheStore store;
  final String prefix;

  /// Store used for stampede locks when [store] cannot lock atomically
  /// across isolates (defaults to [store]).
  final CacheStore? lockStore;

  StateScope get scope => store.scope;

  String _key(String key) => '$prefix$key';

  Future<T?> get<T>(String key, [T? fallback]) async {
    final value = await store.get(_key(key));
    return value is T ? value : fallback;
  }

  Future<bool> has(String key) async => await store.get(_key(key)) != null;

  Future<bool> missing(String key) async => !(await has(key));

  Future<Map<String, Object?>> many(List<String> keys) async {
    final raw = await store.many(keys.map(_key).toList());
    return <String, Object?>{for (final k in keys) k: raw[_key(k)]};
  }

  Future<void> put(String key, Object? value, {Duration? ttl}) =>
      store.put(_key(key), value, ttl: ttl);

  Future<void> putMany(Map<String, Object?> values, {Duration? ttl}) =>
      store.putMany(<String, Object?>{
        for (final e in values.entries) _key(e.key): e.value,
      }, ttl: ttl);

  Future<bool> add(String key, Object? value, {Duration? ttl}) =>
      store.add(_key(key), value, ttl: ttl);

  Future<int> increment(String key, [int by = 1]) =>
      store.increment(_key(key), by);

  Future<int> decrement(String key, [int by = 1]) =>
      store.decrement(_key(key), by);

  Future<void> forever(String key, Object? value) =>
      store.forever(_key(key), value);

  Future<bool> forget(String key) => store.forget(_key(key));

  /// Returns and removes the value.
  Future<T?> pull<T>(String key, [T? fallback]) async {
    final value = await get<T>(key, fallback);
    await forget(key);
    return value;
  }

  Future<void> flush() => store.flush();

  /// Gets or computes-and-stores. Computation is guarded by a per-key lock
  /// so only one caller recomputes (stampede protection); others wait and
  /// read the fresh value.
  Future<T> remember<T>(
    String key,
    Duration? ttl,
    FutureOr<T> Function() compute, {
    Duration lockTimeout = const Duration(seconds: 10),
  }) async {
    final cached = await get<T>(key);
    if (cached != null) {
      return cached;
    }
    return lock('remember:$key', ttl: lockTimeout).block<T>(
      lockTimeout,
      () async {
        final again = await get<T>(key);
        if (again != null) {
          return again;
        }
        final value = await compute();
        await put(key, value, ttl: ttl);
        return value;
      },
    );
  }

  Future<T> rememberForever<T>(String key, FutureOr<T> Function() compute) =>
      remember<T>(key, null, compute);

  /// Stale-while-revalidate (Laravel 11 `Cache::flexible`): fresh for
  /// `fresh`, served stale and refreshed in the background until `stale`,
  /// recomputed inline afterwards.
  Future<T> flexible<T>(
    String key,
    (Duration fresh, Duration stale) window,
    FutureOr<T> Function() compute,
  ) async {
    final (fresh, stale) = window;
    final raw = await store.get(_key(key));
    final now = Clock.now().toUtc().millisecondsSinceEpoch;
    if (raw is Map<String, Object?> && raw['v'] is T && raw['c'] is int) {
      final age = Duration(milliseconds: now - (raw['c'] as int));
      if (age < fresh) {
        return raw['v'] as T;
      }
      if (age < stale) {
        unawaited(_refresh(key, stale, compute));
        return raw['v'] as T;
      }
    }
    final value = await compute();
    await store.put(_key(key), <String, Object?>{
      'v': value,
      'c': now,
    }, ttl: stale);
    return value;
  }

  Future<void> _refresh<T>(
    String key,
    Duration stale,
    FutureOr<T> Function() compute,
  ) async {
    final guard = lock('flexible:$key', ttl: const Duration(seconds: 30));
    if (!await guard.acquire()) {
      return;
    }
    try {
      final value = await compute();
      await store.put(_key(key), <String, Object?>{
        'v': value,
        'c': Clock.now().toUtc().millisecondsSinceEpoch,
      }, ttl: stale);
    } finally {
      await guard.release();
    }
  }

  /// An atomic lock named [name].
  Lock lock(
    String name, {
    Duration ttl = const Duration(seconds: 10),
    String? owner,
  }) => Lock(lockStore ?? store, _key(name), ttl: ttl, owner: owner);
}

/// Holds named stores (Laravel `CacheManager`).
final class CacheManager {
  CacheManager({required this.config, required this.prefix});

  /// Builds the standard stores from configuration.
  factory CacheManager.fromConfig(
    CacheConfig config, {
    required String basePath,
    required DatabaseManager Function() database,
    required CoordinatorChannel channel,
  }) {
    final manager = CacheManager(config: config, prefix: config.prefix);
    final process = ProcessStore(channel);
    manager
      ..extend('memory', () => MemoryStore(maxEntries: config.maxEntries))
      ..extend('process', () => process)
      ..extend(
        'file',
        () => FileStore(
          p.isAbsolute(config.path)
              ? config.path
              : p.join(basePath, config.path),
        ),
        lockStore: process,
      )
      ..extend(
        'database',
        () => DatabaseStore(
          database(),
          table: config.table,
          lockTable: config.lockTable,
        ),
      );
    return manager;
  }

  final CacheConfig config;
  final String prefix;
  final Map<String, ({CacheStore Function() factory, CacheStore? lockStore})>
  _factories = {};
  final Map<String, CacheRepository> _stores = <String, CacheRepository>{};

  /// Registers a store factory under [name]. [lockStore] overrides where
  /// its locks live (file stores delegate to the process store).
  void extend(
    String name,
    CacheStore Function() factory, {
    CacheStore? lockStore,
  }) => _factories[name] = (factory: factory, lockStore: lockStore);

  Iterable<String> get storeNames => _factories.keys;

  /// The store named [name] (default: `CACHE_STORE`).
  CacheRepository store([String? name]) {
    final resolved = name ?? config.defaultStore;
    final existing = _stores[resolved];
    if (existing != null) {
      return existing;
    }
    final entry = _factories[resolved];
    if (entry == null) {
      throw ConfigException(
        'Cache store [$resolved] is not defined (available: '
        '${_factories.keys.join(', ')}).',
      );
    }
    return _stores[resolved] = CacheRepository(
      entry.factory(),
      prefix: prefix,
      lockStore: entry.lockStore,
    );
  }

  /// Flushes every instantiated store.
  Future<void> flushAll() async {
    for (final repository in _stores.values) {
      await repository.flush();
    }
  }
}

/// Creates Laravel's `cache` and `cache_locks` tables (same schema and
/// migration name as Laravel 11's default).
final class CreateCacheTable extends Migration {
  const CreateCacheTable();

  @override
  String get name => '0001_01_01_000001_create_cache_table';

  @override
  Future<void> up(SchemaBuilder schema) async {
    await schema.create('cache', (table) {
      table.string('key').primary();
      table.text('value');
      table.integer('expiration');
    });
    await schema.create('cache_locks', (table) {
      table.string('key').primary();
      table.string('owner');
      table.integer('expiration');
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    await schema.dropIfExists('cache');
    await schema.dropIfExists('cache_locks');
  }
}
