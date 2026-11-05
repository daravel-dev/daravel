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
import 'tags.dart';

/// Backing store contract (BLUEPRINT_V2 §7.7). Values must be
/// JSON-serializable for the file/database stores.
abstract interface class CacheStore {
  /// Where the values live: one isolate, the process, or the cluster.
  StateScope get scope;

  /// The value of [key], or null.
  Future<Object?> get(String key);

  /// The values of [keys], null for the missing ones.
  Future<Map<String, Object?>> many(List<String> keys);

  /// Stores [value] for [ttl] (`null` = forever).
  Future<void> put(String key, Object? value, {Duration? ttl});

  /// Stores every entry of [values], for [ttl] or forever.
  Future<void> putMany(Map<String, Object?> values, {Duration? ttl});

  /// Stores only when [key] is absent (atomic per store scope).
  Future<bool> add(String key, Object? value, {Duration? ttl});

  /// Adds [by] to the integer under [key] and returns the new value.
  Future<int> increment(String key, [int by = 1]);

  /// Subtracts [by] from the integer under [key] and returns the new value.
  Future<int> decrement(String key, [int by = 1]);

  /// Stores [value] under [key] with no expiry.
  Future<void> forever(String key, Object? value);

  /// Removes [key]; returns whether it existed.
  Future<bool> forget(String key);

  /// Removes every value.
  Future<void> flush();

  /// Takes the lock [name] for [owner] during [ttl]; returns whether it
  /// was free.
  Future<bool> acquireLock(String name, String owner, Duration ttl);

  /// Releases the lock [name] if [owner] holds it; returns whether it did.
  Future<bool> releaseLock(String name, String owner);

  /// Releases the lock [name] whoever holds it.
  Future<void> forceReleaseLock(String name);

  /// The owner of the lock [name], or null when it is free.
  Future<String?> lockOwner(String name);
}

/// A store that can change how long a key lives without rewriting its value
/// (Laravel's `Cache::touch`), so a concurrent `increment` is never lost.
abstract interface class TouchableCacheStore implements CacheStore {
  /// Makes [key] expire [ttl] from now; `false` when [key] is missing.
  Future<bool> touch(String key, Duration ttl);
}

/// A store that counts fixed-window hits in one atomic step, for rate limits
/// over the network (`CACHE_LIMITER=database`): one round trip per attempt
/// instead of a read-modify-write sequence.
abstract interface class WindowCounterStore implements CacheStore {
  /// Counts a hit on [key] unless [maxHits] were already counted in its
  /// window, which [window] starts when [key] has none. [allowed] says
  /// whether this hit was counted; [hits] never exceeds [maxHits].
  Future<({bool allowed, int hits, DateTime resetAt})> hitWindow(
    String key,
    int maxHits,
    Duration window,
  );

  /// Hits counted in the current window of [key], or null without one.
  Future<({int hits, DateTime resetAt})?> currentWindow(String key);
}

/// A store that counts rate limits as a sliding window or with the generic
/// cell rate algorithm, in one atomic step on the server's clock
/// (daravel_redis). [resetIn] is how long until the key holds no hits;
/// [retryAfter] how long until a refused hit would be counted.
abstract interface class RateCounterStore implements CacheStore {
  /// Counts a hit of [key] in a sliding window of [maxHits] per [window].
  Future<({bool allowed, int remaining, Duration resetIn, Duration retryAfter})>
  hitSlidingWindow(String key, int maxHits, Duration window);

  /// Counts a hit of [key] with the generic cell rate algorithm.
  Future<({bool allowed, int remaining, Duration resetIn, Duration retryAfter})>
  hitGcra(String key, int maxHits, Duration window);
}

/// Raised by [Lock.block] when the lock cannot be obtained in time.
final class LockTimeoutException extends DaravelException {
  /// The lock [name] could not be taken within [timeout].
  LockTimeoutException(String name, Duration timeout)
    : super(
        'Could not acquire lock [$name] within ${timeout.inMilliseconds}ms.',
      );
}

/// An atomic lock (Laravel `Cache::lock`). Semantics are **fail-closed**:
/// a coordinator error surfaces as an exception instead of a false "got it".
final class Lock {
  /// A lock named [name] held for [ttl] by [owner] (a random id by default).
  Lock(
    this._store,
    this.name, {
    this.ttl = const Duration(seconds: 10),
    String? owner,
  }) : owner = owner ?? _randomOwner();

  final CacheStore _store;

  /// The lock's name.
  final String name;

  /// How long the lock lasts unless released.
  final Duration ttl;

  /// Who holds it; pass the same owner to release it from another process.
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

  /// Takes the lock if it is free; returns whether it did.
  Future<bool> acquire() => _store.acquireLock(name, owner, ttl);

  /// Releases only when this instance owns the lock.
  Future<bool> release() => _store.releaseLock(name, owner);

  /// Releases the lock whoever holds it.
  Future<void> forceRelease() => _store.forceReleaseLock(name);

  /// The current owner, or null when the lock is free.
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
  /// Cache settings; usually from `.env` ([CacheConfig.fromEnv]).
  const CacheConfig({
    this.defaultStore = 'memory',
    this.prefix = 'daravel_cache_',
    this.path = 'storage/framework/cache',
    this.table = 'cache',
    this.lockTable = 'cache_locks',
    this.maxEntries = 10000,
    this.processMaxEntries = 10000,
    this.processL1Ttl = Duration.zero,
    this.limiter,
  });

  /// The settings in `CACHE_*`.
  factory CacheConfig.fromEnv(Env env) {
    final appName = env.string('APP_NAME', 'daravel');
    return CacheConfig(
      defaultStore: switch (env.string('CACHE_STORE', 'memory')) {
        CacheManager.arrayStore => 'memory',
        final store => store,
      },
      prefix: env.string(
        'CACHE_PREFIX',
        '${appName.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_')}_cache_',
      ),
      path: env.string('CACHE_PATH', 'storage/framework/cache'),
      table: env.string('CACHE_TABLE', 'cache'),
      lockTable: env.string('CACHE_LOCK_TABLE', 'cache_locks'),
      maxEntries: env.integer('CACHE_MAX_ENTRIES', 10000),
      processMaxEntries: env.integer('CACHE_PROCESS_MAX_ENTRIES', 10000),
      processL1Ttl: env.duration('CACHE_PROCESS_L1_TTL', Duration.zero),
      limiter: switch (env.string('CACHE_LIMITER', '')) {
        '' => null,
        final store => store,
      },
    );
  }

  /// `memory` | `process` | `file` | `database`. `CACHE_STORE=array`
  /// (Laravel's in-memory store, common in `phpunit.xml`) reads as
  /// `memory`.
  final String defaultStore;

  /// The prefix of every key (`CACHE_PREFIX`).
  final String prefix;

  /// The directory of the file store (`CACHE_PATH`).
  final String path;

  /// The table of the database store (`cache`).
  final String table;

  /// The locks table of the database store (`cache_locks`).
  final String lockTable;

  /// The most entries the memory store keeps.
  final int maxEntries;

  /// Entries the `process` store keeps for the whole server
  /// (`CACHE_PROCESS_MAX_ENTRIES`, 10 000); the least recently used go
  /// first, silently. Raise it when the store holds many keys that must
  /// not be lost before they expire (revoked tokens, counters per client),
  /// or move those to a persistent store.
  final int processMaxEntries;

  /// How long each worker isolate may reuse a value read from the `process`
  /// store before asking the coordinator again (`CACHE_PROCESS_L1_TTL`, e.g.
  /// `250ms`). Zero (the default) disables the near cache.
  final Duration processL1Ttl;

  /// The cache store rate limits count in (`CACHE_LIMITER`, Laravel's
  /// `cache.limiter`), e.g. `database` to share them between machines.
  /// Null keeps the default: the coordinator, shared by this machine's
  /// isolates.
  final String? limiter;

  @override
  String get key => 'cache';

  @override
  Map<String, Object?> toMap() => <String, Object?>{
    'default': defaultStore,
    'limiter': limiter,
    'prefix': prefix,
    'stores': {
      'memory': {'driver': 'memory', 'max_entries': maxEntries},
      'process': {
        'driver': 'process',
        'max_entries': processMaxEntries,
        'l1_ttl': processL1Ttl.inMilliseconds,
      },
      'file': {'driver': 'file', 'path': path},
      'database': {
        'driver': 'database',
        'table': table,
        'lock_table': lockTable,
      },
    },
  };
}

/// A store that shapes the key prefix its repository applies, as Laravel's
/// stores own their prefix: `RedisStore::setPrefix` appended `:` to a
/// non-empty prefix up to Laravel 10 and keeps it as given from 11.
abstract interface class CachePrefixShaping {
  /// The prefix put before every key (and lock name), from `CACHE_PREFIX`.
  String shapePrefix(String prefix);
}

/// A store wrapped with a key prefix and the high-level API
/// (`remember`, `flexible`, `lock`, …).
final class CacheRepository {
  /// A repository over [store], prefixing every key with [prefix] (as the
  /// store shapes it, when it is [CachePrefixShaping]).
  CacheRepository(
    this.store, {
    String prefix = '',
    this.lockStore,
    this._lockPrefix,
  }) : prefix = switch (store) {
         final CachePrefixShaping shaping => shaping.shapePrefix(prefix),
         _ => prefix,
       };

  /// The store holding the values.
  final CacheStore store;

  /// The key prefix.
  final String prefix;

  /// Store used for stampede locks when [store] cannot lock atomically
  /// across isolates (defaults to [store]).
  final CacheStore? lockStore;

  /// What lock names get before them, when not [prefix] (a tagged
  /// repository's locks are not tagged).
  final String? _lockPrefix;

  /// The store's scope.
  StateScope get scope => store.scope;

  String _key(String key) => '$prefix$key';

  /// This cache with its entries tagged [names] (Laravel's `Cache::tags`):
  /// `flush()` on it forgets only what those tags hold. Reads use the same
  /// tags, in the same order. [UnsupportedError] on stores that cannot tag
  /// (`file`, `database`), as Laravel's `BadMethodCallException`.
  CacheRepository tags(List<String> names) {
    final store = this.store;
    if (store is! TaggableCacheStore) {
      throw UnsupportedError('This cache store does not support tagging.');
    }
    return CacheRepository(
      store.tags(names, prefix: prefix),
      lockStore: lockStore ?? store,
      lockPrefix: _lockPrefix ?? prefix,
    );
  }

  /// The value of [key], or [fallback] when missing.
  Future<T?> get<T>(String key, [T? fallback]) async {
    final value = await store.get(_key(key));
    return value is T ? value : fallback;
  }

  /// Whether [key] holds a value.
  Future<bool> has(String key) async => await store.get(_key(key)) != null;

  /// Whether [key] holds nothing.
  Future<bool> missing(String key) async => !(await has(key));

  /// The values of [keys], null for the missing ones.
  Future<Map<String, Object?>> many(List<String> keys) async {
    final raw = await store.many(keys.map(_key).toList());
    return <String, Object?>{for (final k in keys) k: raw[_key(k)]};
  }

  /// Stores [value] under [key], for [ttl] or forever.
  Future<void> put(String key, Object? value, {Duration? ttl}) =>
      store.put(_key(key), value, ttl: ttl);

  /// Stores every entry of [values].
  Future<void> putMany(Map<String, Object?> values, {Duration? ttl}) =>
      store.putMany(<String, Object?>{
        for (final e in values.entries) _key(e.key): e.value,
      }, ttl: ttl);

  /// Stores [value] only when [key] is missing; returns whether it did.
  Future<bool> add(String key, Object? value, {Duration? ttl}) =>
      store.add(_key(key), value, ttl: ttl);

  /// Adds [by] to the integer under [key].
  Future<int> increment(String key, [int by = 1]) =>
      store.increment(_key(key), by);

  /// Subtracts [by] from the integer under [key].
  Future<int> decrement(String key, [int by = 1]) =>
      store.decrement(_key(key), by);

  /// Stores [value] under [key] with no expiry.
  Future<void> forever(String key, Object? value) =>
      store.forever(_key(key), value);

  /// Removes [key]; returns whether it existed.
  Future<bool> forget(String key) => store.forget(_key(key));

  /// Laravel's `Cache::touch()`: a new [ttl] for [key], keeping its value.
  /// `false` when it is missing, and a [ttl] of zero or less forgets it.
  Future<bool> touch(String key, Duration ttl) async {
    if (ttl <= Duration.zero) {
      return forget(key);
    }
    final target = store;
    if (target is TouchableCacheStore) {
      return target.touch(_key(key), ttl);
    }
    // A store without an atomic touch: another writer can slip in between.
    final value = await target.get(_key(key));
    if (value == null) {
      return false;
    }
    await target.put(_key(key), value, ttl: ttl);
    return true;
  }

  /// Returns and removes the value.
  Future<T?> pull<T>(String key, [T? fallback]) async {
    final value = await get<T>(key, fallback);
    await forget(key);
    return value;
  }

  /// Removes every value of the store.
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

  /// The value of [key], or [compute]'s result stored forever.
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
  }) => Lock(
    lockStore ?? store,
    '${_lockPrefix ?? prefix}$name',
    ttl: ttl,
    owner: owner,
  );
}

/// Holds named stores (Laravel `CacheManager`).
final class CacheManager {
  /// A manager of the stores in [config], prefixing keys with [prefix].
  CacheManager({required this.config, required this.prefix});

  /// Builds the standard stores from configuration.
  factory CacheManager.fromConfig(
    CacheConfig config, {
    required String basePath,
    required DatabaseManager Function() database,
    required CoordinatorChannel channel,
  }) {
    final manager = CacheManager(config: config, prefix: config.prefix);
    final process = ProcessStore(
      channel,
      l1Ttl: config.processL1Ttl > Duration.zero ? config.processL1Ttl : null,
    );
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

  /// The cache settings.
  final CacheConfig config;

  /// The key prefix.
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

  /// The names of the configured stores.
  Iterable<String> get storeNames => _factories.keys;

  /// Laravel's `array` store, an alias of `memory` unless a store of that
  /// name is registered with [extend].
  static const String arrayStore = 'array';

  /// The store named [name] (default: `CACHE_STORE`). `array` is the
  /// `memory` store ([arrayStore]).
  CacheRepository store([String? name]) {
    var resolved = name ?? config.defaultStore;
    if (resolved == arrayStore && !_factories.containsKey(arrayStore)) {
      resolved = 'memory';
    }
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
  /// The migration creating `cache` and `cache_locks`, as Laravel's.
  const CreateCacheTable();

  @override
  String get name => '0001_01_01_000001_create_cache_table';

  @override
  Future<void> up(SchemaBuilder schema) async {
    await schema.create('cache', (table) {
      table.string('key').primary();
      table.mediumText('value');
      table.integer('expiration').index();
    });
    await schema.create('cache_locks', (table) {
      table.string('key').primary();
      table.string('owner');
      table.integer('expiration').index();
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    await schema.dropIfExists('cache');
    await schema.dropIfExists('cache_locks');
  }
}
