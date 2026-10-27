import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../foundation/clock.dart';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../database/database_manager.dart';
import '../database/query/query_builder.dart';
import '../server/coordinator.dart';
import 'cache.dart';

final class _Entry {
  _Entry(this.value, this.expiresAt);
  Object? value;
  int? expiresAt;
}

/// Bounded LRU store in this isolate's memory (scope `isolate`).
final class MemoryStore implements TouchableCacheStore {
  MemoryStore({this.maxEntries = 10000, DateTime Function()? clock})
    : _clock = clock ?? _utcNow;

  final int maxEntries;
  final DateTime Function() _clock;
  final LinkedHashMap<String, _Entry> _entries =
      LinkedHashMap<String, _Entry>();
  final Map<String, ({String owner, int expiresAt})> _locks = {};

  @override
  StateScope get scope => StateScope.isolate;

  int get size => _entries.length;

  int get _now => _clock().millisecondsSinceEpoch;

  _Entry? _live(String key) {
    final entry = _entries.remove(key);
    if (entry == null) {
      return null;
    }
    final exp = entry.expiresAt;
    if (exp != null && exp <= _now) {
      return null;
    }
    _entries[key] = entry; // most recently used
    return entry;
  }

  @override
  Future<bool> touch(String key, Duration ttl) async {
    final entry = _live(key);
    if (entry == null) {
      return false;
    }
    entry.expiresAt = _now + ttl.inMilliseconds;
    return true;
  }

  void _store(String key, Object? value, Duration? ttl) {
    _entries.remove(key);
    _entries[key] = _Entry(
      value,
      ttl == null ? null : _now + ttl.inMilliseconds,
    );
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
  }

  @override
  Future<Object?> get(String key) async => _live(key)?.value;

  @override
  Future<Map<String, Object?>> many(List<String> keys) async =>
      <String, Object?>{for (final k in keys) k: _live(k)?.value};

  @override
  Future<void> put(String key, Object? value, {Duration? ttl}) async =>
      _store(key, value, ttl);

  @override
  Future<void> putMany(Map<String, Object?> values, {Duration? ttl}) async {
    for (final e in values.entries) {
      _store(e.key, e.value, ttl);
    }
  }

  @override
  Future<bool> add(String key, Object? value, {Duration? ttl}) async {
    if (_live(key) != null) {
      return false;
    }
    _store(key, value, ttl);
    return true;
  }

  @override
  Future<int> increment(String key, [int by = 1]) async {
    final entry = _live(key);
    final current = entry?.value;
    final next = (current is num ? current.toInt() : 0) + by;
    if (entry == null) {
      _store(key, next, null);
    } else {
      entry.value = next;
    }
    return next;
  }

  @override
  Future<int> decrement(String key, [int by = 1]) => increment(key, -by);

  @override
  Future<void> forever(String key, Object? value) async =>
      _store(key, value, null);

  @override
  Future<bool> forget(String key) async => _entries.remove(key) != null;

  @override
  Future<void> flush() async {
    _entries.clear();
    _locks.clear();
  }

  @override
  Future<bool> acquireLock(String name, String owner, Duration ttl) async =>
      acquireLockSync(name, owner, ttl);

  bool acquireLockSync(String name, String owner, Duration ttl) {
    final existing = _locks[name];
    if (existing != null &&
        existing.expiresAt > _now &&
        existing.owner != owner) {
      return false;
    }
    _locks[name] = (owner: owner, expiresAt: _now + ttl.inMilliseconds);
    return true;
  }

  @override
  Future<bool> releaseLock(String name, String owner) async =>
      releaseLockSync(name, owner);

  bool releaseLockSync(String name, String owner) {
    final existing = _locks[name];
    if (existing == null || existing.owner != owner) {
      return false;
    }
    _locks.remove(name);
    return true;
  }

  @override
  Future<void> forceReleaseLock(String name) async => _locks.remove(name);

  @override
  Future<String?> lockOwner(String name) async => lockOwnerSync(name);

  String? lockOwnerSync(String name) {
    final existing = _locks[name];
    if (existing == null || existing.expiresAt <= _now) {
      return null;
    }
    return existing.owner;
  }

  static DateTime _utcNow() => Clock.now().toUtc();
}

/// Coordinator service exposing a [MemoryStore] to every worker
/// (`process`-scope cache and locks).
final class ProcessCacheService implements CoordinatorService {
  ProcessCacheService([MemoryStore? store]) : store = store ?? MemoryStore();

  static const String serviceName = 'processCache';

  final MemoryStore store;

  @override
  String get name => serviceName;

  @override
  Future<Object?> handle(String op, Map<String, Object?> args) async {
    final key = args['key'] as String? ?? '';
    final ttlMs = args['ttl'] as int?;
    final ttl = ttlMs == null ? null : Duration(milliseconds: ttlMs);
    switch (op) {
      case 'get':
        return store.get(key);
      case 'many':
        return store.many((args['keys']! as List<Object?>).cast<String>());
      case 'put':
        await store.put(key, args['value'], ttl: ttl);
        return null;
      case 'putMany':
        await store.putMany(args['values']! as Map<String, Object?>, ttl: ttl);
        return null;
      case 'add':
        return store.add(key, args['value'], ttl: ttl);
      case 'increment':
        return store.increment(key, args['by'] as int? ?? 1);
      case 'forget':
        return store.forget(key);
      case 'flush':
        await store.flush();
        return null;
      case 'acquireLock':
        return store.acquireLockSync(
          key,
          args['owner']! as String,
          Duration(milliseconds: ttlMs ?? 10000),
        );
      case 'releaseLock':
        return store.releaseLockSync(key, args['owner']! as String);
      case 'forceReleaseLock':
        await store.forceReleaseLock(key);
        return null;
      case 'lockOwner':
        return store.lockOwnerSync(key);
      default:
        throw CoordinatorException('Unknown processCache op [$op].');
    }
  }

  @override
  Map<String, Object?> stats() => <String, Object?>{'entries': store.size};
}

/// Process-wide cache and locks via the coordinator (scope `process`).
/// Lock calls are **fail-closed**: coordinator errors propagate.
///
/// With [l1Ttl], each isolate keeps the values it reads for that long (up to
/// [l1MaxEntries]) and answers repeated reads without a coordinator round
/// trip; its own writes update or drop them at once, while writes from
/// other isolates show up within [l1Ttl]. Misses, counters and locks always
/// go to the coordinator.
final class ProcessStore implements CacheStore {
  ProcessStore(
    this.channel, {
    this.timeout = const Duration(seconds: 1),
    this.l1Ttl,
    this.l1MaxEntries = 1000,
  });

  final CoordinatorChannel channel;
  final Duration timeout;
  final Duration? l1Ttl;
  final int l1MaxEntries;

  /// Near cache: key → (value, expiry on [_l1Clock] in microseconds). A
  /// monotonic clock: staleness is wall time, not `Clock` (tests may freeze
  /// domain time).
  final Map<String, (Object?, int)> _l1 = <String, (Object?, int)>{};
  final Stopwatch _l1Clock = Stopwatch()..start();

  @override
  StateScope get scope => StateScope.process;

  Future<Object?> _call(String op, [Map<String, Object?> args = const {}]) =>
      channel.call(ProcessCacheService.serviceName, op, args, timeout: timeout);

  Object? _l1Read(String key) {
    final entry = _l1[key];
    if (entry == null) {
      return null;
    }
    if (entry.$2 <= _l1Clock.elapsedMicroseconds) {
      _l1.remove(key);
      return null;
    }
    return _copy(entry.$1);
  }

  void _l1Write(String key, Object? value) {
    final ttl = l1Ttl;
    _l1.remove(key);
    if (ttl == null || value == null) {
      return;
    }
    if (_l1.length >= l1MaxEntries) {
      _l1.remove(_l1.keys.first); // Oldest first (insertion order).
    }
    _l1[key] = (
      _copy(value),
      _l1Clock.elapsedMicroseconds + ttl.inMicroseconds,
    );
  }

  /// Callers get their own copy, so mutating a cached map is harmless.
  static Object? _copy(Object? value) => switch (value) {
    final Map<Object?, Object?> map => <Object?, Object?>{
      for (final MapEntry(:key, :value) in map.entries) key: _copy(value),
    },
    final List<Object?> list => [for (final item in list) _copy(item)],
    _ => value,
  };

  @override
  Future<Object?> get(String key) async {
    if (l1Ttl != null) {
      final cached = _l1Read(key);
      if (cached != null) {
        return cached;
      }
    }
    final value = await _call('get', {'key': key});
    _l1Write(key, value);
    return value;
  }

  @override
  Future<Map<String, Object?>> many(List<String> keys) async {
    final values =
        (await _call('many', {'keys': keys}))! as Map<String, Object?>;
    values.forEach(_l1Write);
    return values;
  }

  @override
  Future<void> put(String key, Object? value, {Duration? ttl}) async {
    _l1.remove(key);
    await _call('put', {
      'key': key,
      'value': value,
      'ttl': ttl?.inMilliseconds,
    });
    _l1Write(key, value);
  }

  @override
  Future<void> putMany(Map<String, Object?> values, {Duration? ttl}) async {
    values.keys.forEach(_l1.remove);
    await _call('putMany', {'values': values, 'ttl': ttl?.inMilliseconds});
    values.forEach(_l1Write);
  }

  @override
  Future<bool> add(String key, Object? value, {Duration? ttl}) async {
    _l1.remove(key);
    return await _call('add', {
      'key': key,
      'value': value,
      'ttl': ttl?.inMilliseconds,
    }) as bool;
  }

  @override
  Future<int> increment(String key, [int by = 1]) async {
    _l1.remove(key);
    return await _call('increment', {'key': key, 'by': by}) as int;
  }

  @override
  Future<int> decrement(String key, [int by = 1]) => increment(key, -by);

  @override
  Future<void> forever(String key, Object? value) => put(key, value);

  @override
  Future<bool> forget(String key) async {
    _l1.remove(key);
    return await _call('forget', {'key': key}) as bool;
  }

  @override
  Future<void> flush() async {
    _l1.clear();
    await _call('flush');
  }

  @override
  Future<bool> acquireLock(String name, String owner, Duration ttl) async =>
      await _call('acquireLock', {
        'key': name,
        'owner': owner,
        'ttl': ttl.inMilliseconds,
      }) as bool;

  @override
  Future<bool> releaseLock(String name, String owner) async =>
      await _call('releaseLock', {'key': name, 'owner': owner}) as bool;

  @override
  Future<void> forceReleaseLock(String name) =>
      _call('forceReleaseLock', {'key': name});

  @override
  Future<String?> lockOwner(String name) async =>
      await _call('lockOwner', {'key': name}) as String?;
}

/// JSON files under a directory (scope `cluster` on a shared disk, otherwise
/// `process`). Writes go to a temp file then `rename` (atomic on POSIX and
/// NTFS). Locks use exclusive file creation.
final class FileStore implements TouchableCacheStore {
  FileStore(this.directory);

  final String directory;

  @override
  StateScope get scope => StateScope.process;

  String _path(String key) {
    final hash = crypto.sha1.convert(utf8.encode(key)).toString();
    return p.join(directory, hash.substring(0, 2), '$hash.json');
  }

  String _lockPath(String name) => p.join(
    directory,
    'locks',
    '${crypto.sha1.convert(utf8.encode(name))}.lock',
  );

  static int get _now => Clock.now().toUtc().millisecondsSinceEpoch;

  Future<Map<String, Object?>?> _read(String key) async {
    final file = File(_path(key));
    if (!await file.exists()) {
      return null;
    }
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<String, Object?>) {
        return null;
      }
      final exp = decoded['e'] as int?;
      if (exp != null && exp <= _now) {
        await _delete(file);
        return null;
      }
      return decoded;
    } on FormatException {
      return null;
    } on FileSystemException {
      return null;
    }
  }

  Future<void> _write(String key, Object? value, Duration? ttl) async {
    final file = File(_path(key));
    await file.parent.create(recursive: true);
    final payload = jsonEncode(<String, Object?>{
      'e': ttl == null ? null : _now + ttl.inMilliseconds,
      'v': value,
    });
    final temp = File('${file.path}.${pid}_$_now.tmp');
    await temp.writeAsString(payload, flush: true);
    await temp.rename(file.path);
  }

  static Future<void> _delete(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }

  @override
  Future<Object?> get(String key) async => (await _read(key))?['v'];

  @override
  Future<bool> touch(String key, Duration ttl) async {
    final entry = await _read(key);
    if (entry == null) {
      return false;
    }
    await _write(key, entry['v'], ttl);
    return true;
  }

  @override
  Future<Map<String, Object?>> many(List<String> keys) async =>
      <String, Object?>{for (final k in keys) k: await get(k)};

  @override
  Future<void> put(String key, Object? value, {Duration? ttl}) =>
      _write(key, value, ttl);

  @override
  Future<void> putMany(Map<String, Object?> values, {Duration? ttl}) async {
    for (final e in values.entries) {
      await _write(e.key, e.value, ttl);
    }
  }

  @override
  Future<bool> add(String key, Object? value, {Duration? ttl}) async {
    if (await _read(key) != null) {
      return false;
    }
    await _write(key, value, ttl);
    return true;
  }

  @override
  Future<int> increment(String key, [int by = 1]) async {
    final current = await _read(key);
    final value = current?['v'];
    final next = (value is num ? value.toInt() : 0) + by;
    final exp = current?['e'] as int?;
    await _write(
      key,
      next,
      exp == null ? null : Duration(milliseconds: exp - _now),
    );
    return next;
  }

  @override
  Future<int> decrement(String key, [int by = 1]) => increment(key, -by);

  @override
  Future<void> forever(String key, Object? value) => _write(key, value, null);

  @override
  Future<bool> forget(String key) async {
    final file = File(_path(key));
    if (!await file.exists()) {
      return false;
    }
    await _delete(file);
    return true;
  }

  @override
  Future<void> flush() async {
    final dir = Directory(directory);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
  }

  @override
  Future<bool> acquireLock(String name, String owner, Duration ttl) async {
    final file = File(_lockPath(name));
    await file.parent.create(recursive: true);
    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        await file.create(exclusive: true);
        await file.writeAsString(
          jsonEncode({'o': owner, 'e': _now + ttl.inMilliseconds}),
          flush: true,
        );
        return true;
      } on FileSystemException {
        final current = await _readLock(file);
        if (current == null) {
          continue; // corrupt/missing → retry
        }
        if (current.owner == owner || current.expiresAt <= _now) {
          await _delete(file);
          continue;
        }
        return false;
      }
    }
    return false;
  }

  Future<({String owner, int expiresAt})?> _readLock(File file) async {
    try {
      final decoded = jsonDecode(await file.readAsString());
      if (decoded is Map<String, Object?> && decoded['o'] is String) {
        return (
          owner: decoded['o']! as String,
          expiresAt: decoded['e'] as int? ?? 0,
        );
      }
    } on FormatException {
      // fallthrough
    } on FileSystemException {
      return null;
    }
    await _delete(file);
    return null;
  }

  @override
  Future<bool> releaseLock(String name, String owner) async {
    final file = File(_lockPath(name));
    final current = await _readLock(file);
    if (current == null || current.owner != owner) {
      return false;
    }
    await _delete(file);
    return true;
  }

  @override
  Future<void> forceReleaseLock(String name) => _delete(File(_lockPath(name)));

  @override
  Future<String?> lockOwner(String name) async {
    final current = await _readLock(File(_lockPath(name)));
    if (current == null || current.expiresAt <= _now) {
      return null;
    }
    return current.owner;
  }
}

/// Laravel-compatible `cache` / `cache_locks` tables (scope `cluster`).
final class DatabaseStore implements TouchableCacheStore, WindowCounterStore {
  DatabaseStore(
    this.db, {
    this.table = 'cache',
    this.lockTable = 'cache_locks',
    this.connection,
  });

  final DatabaseManager db;
  final String table;
  final String lockTable;
  final String? connection;

  /// Laravel stores "forever" as this far-future timestamp.
  static const int foreverExpiration = 9999999999;

  @override
  StateScope get scope => StateScope.cluster;

  static int get _now => Clock.now().toUtc().millisecondsSinceEpoch ~/ 1000;

  int _expiration(Duration? ttl) => ttl == null
      ? foreverExpiration
      : _now + (ttl.inMilliseconds / 1000).ceil();

  Future<Map<String, Object?>?> _row(String key) async {
    final row = await db
        .table(table, connection: connection)
        .where('key', key)
        .first();
    if (row == null) {
      return null;
    }
    final exp = (row['expiration'] as num?)?.toInt() ?? 0;
    if (exp <= _now) {
      await db.table(table, connection: connection).where('key', key).delete();
      return null;
    }
    return row;
  }

  static Object? _decode(Object? raw) =>
      raw is String ? (jsonDecode(raw) as Map<String, Object?>)['v'] : null;

  static String _encode(Object? value) =>
      jsonEncode(<String, Object?>{'v': value});

  @override
  Future<Object?> get(String key) async => _decode((await _row(key))?['value']);

  @override
  Future<Map<String, Object?>> many(List<String> keys) async =>
      <String, Object?>{for (final k in keys) k: await get(k)};

  @override
  Future<void> put(String key, Object? value, {Duration? ttl}) => db
      .table(table, connection: connection)
      .upsert(
        <String, Object?>{
          'key': key,
          'value': _encode(value),
          'expiration': _expiration(ttl),
        },
        const ['key'],
      );

  @override
  Future<void> putMany(Map<String, Object?> values, {Duration? ttl}) async {
    for (final e in values.entries) {
      await put(e.key, e.value, ttl: ttl);
    }
  }

  @override
  Future<bool> add(String key, Object? value, {Duration? ttl}) async {
    final query = db.table(table, connection: connection);
    try {
      await query.insert(<String, Object?>{
        'key': key,
        'value': _encode(value),
        'expiration': _expiration(ttl),
      });
      return true;
    } catch (_) {
      // Exists: take over only when expired.
      final updated = await db
          .table(table, connection: connection)
          .where('key', key)
          .where('expiration', '<=', _now)
          .update(<String, Object?>{
            'value': _encode(value),
            'expiration': _expiration(ttl),
          });
      return updated > 0;
    }
  }

  /// Changes only the expiration, so a concurrent `increment` is kept.
  @override
  Future<bool> touch(String key, Duration ttl) async =>
      await db
          .table(table, connection: connection)
          .where('key', key)
          .where('expiration', '>', _now)
          .update(<String, Object?>{'expiration': _expiration(ttl)}) >
      0;

  /// Atomic across connections, processes and machines: a compare-and-swap
  /// (`UPDATE ... WHERE value = <read value>`) retried when another writer
  /// got in first. A read-then-write, even in a transaction, loses updates
  /// under READ COMMITTED, and a row lock would deadlock SQLite's deferred
  /// transactions across isolates.
  @override
  Future<int> increment(String key, [int by = 1]) async {
    for (var attempt = 1; ; attempt++) {
      final row = await _row(key);
      if (row == null) {
        final inserted = await db
            .table(table, connection: connection)
            .insertOrIgnore(<String, Object?>{
              'key': key,
              'value': _encode(by),
              'expiration': foreverExpiration,
            });
        if (inserted > 0) {
          return by;
        }
      } else {
        final current = _decode(row['value']);
        final next = (current is num ? current.toInt() : 0) + by;
        final swapped = await db
            .table(table, connection: connection)
            .where('key', key)
            .where('value', row['value'])
            .update(<String, Object?>{'value': _encode(next)});
        if (swapped > 0) {
          return next;
        }
      }
      if (attempt >= 1000) {
        throw StateError('Cache increment of [$key] kept losing races.');
      }
    }
  }

  @override
  Future<int> decrement(String key, [int by = 1]) => increment(key, -by);

  /// One upsert per hit: the row holds the hits as plain digits and the end
  /// of the window as its expiration. A blocked hit turns `max` into `-max`
  /// (saturated), so the statement's result alone says whether this hit
  /// counted; `RETURNING` reads it back in the same statement (MySQL, which
  /// has none, reads it in the same transaction, where the row stays locked).
  @override
  Future<({bool allowed, int hits, DateTime resetAt})> hitWindow(
    String key,
    int maxHits,
    Duration window,
  ) async {
    final now = _now;
    final end = _expiration(window);
    if (maxHits <= 0) {
      return (allowed: false, hits: 0, resetAt: _time(end));
    }
    final grammar = db.grammarFor(connection);
    final dialect = db.dialectOf(connection);
    final (number, text) = switch (dialect) {
      .postgres => ('BIGINT', 'TEXT'),
      .mysql => ('SIGNED', 'CHAR'),
      .sqlite => ('INTEGER', 'TEXT'),
    };
    final t = grammar.wrap(table);
    final k = grammar.wrap('key');
    final v = grammar.wrap('value');
    final e = grammar.wrap('expiration');
    final oldValue = grammar.wrap('$table.value');
    final oldEnd = grammar.wrap('$table.expiration');
    final hits = 'CAST($oldValue AS $number)';
    // MySQL assigns left to right: the value reads the old expiration
    // before the expiration is assigned, as in the other dialects.
    final sets =
        "$v = CASE WHEN $oldEnd <= ? THEN '1' "
        'WHEN $hits < 0 THEN $oldValue '
        'WHEN $hits < ? THEN CAST($hits + 1 AS $text) '
        'ELSE CAST(-$hits AS $text) END, '
        '$e = CASE WHEN $oldEnd <= ? THEN ? ELSE $oldEnd END';
    final insert = "INSERT INTO $t ($k, $v, $e) VALUES (?, '1', ?)";
    final upsert = dialect == .mysql
        ? '$insert ON DUPLICATE KEY UPDATE $sets'
        : '$insert ON CONFLICT ($k) DO UPDATE SET $sets';
    final bindings = <Object?>[key, end, now, maxHits, now, end];
    final List<Map<String, Object?>> rows;
    if (grammar.supportsReturning) {
      rows = await db.select('$upsert RETURNING $v, $e', bindings, connection);
    } else {
      rows = await db.transaction(() async {
        await db.statement(upsert, bindings, connection);
        return db.select('SELECT $v, $e FROM $t WHERE $k = ?', <Object?>[
          key,
        ], connection);
      }, connection: connection);
    }
    final count = int.parse('${rows.single['value']}');
    return (
      allowed: count > 0,
      hits: count.abs(),
      resetAt: _time((rows.single['expiration']! as num).toInt()),
    );
  }

  @override
  Future<({int hits, DateTime resetAt})?> currentWindow(String key) async {
    final row = await db
        .table(table, connection: connection)
        .where('key', key)
        .where('expiration', '>', _now)
        .first();
    if (row == null) {
      return null;
    }
    return (
      hits: (int.tryParse('${row['value']}') ?? 0).abs(),
      resetAt: _time((row['expiration']! as num).toInt()),
    );
  }

  static DateTime _time(int seconds) =>
      DateTime.fromMillisecondsSinceEpoch(seconds * 1000, isUtc: true);

  @override
  Future<void> forever(String key, Object? value) => put(key, value);

  @override
  Future<bool> forget(String key) async =>
      await db.table(table, connection: connection).where('key', key).delete() >
      0;

  @override
  Future<void> flush() async {
    await db.table(table, connection: connection).delete();
    await db.table(lockTable, connection: connection).delete();
  }

  @override
  Future<bool> acquireLock(String name, String owner, Duration ttl) async {
    final expiration = _now + (ttl.inMilliseconds / 1000).ceil();
    try {
      await db.table(lockTable, connection: connection).insert(
        <String, Object?>{
          'key': name,
          'owner': owner,
          'expiration': expiration,
        },
      );
      return true;
    } catch (_) {
      final updated = await db
          .table(lockTable, connection: connection)
          .where('key', name)
          .where((QueryBuilder q) {
            q.where('owner', owner).orWhere('expiration', '<=', _now);
          })
          .update(<String, Object?>{'owner': owner, 'expiration': expiration});
      return updated > 0;
    }
  }

  @override
  Future<bool> releaseLock(String name, String owner) async =>
      await db
          .table(lockTable, connection: connection)
          .where('key', name)
          .where('owner', owner)
          .delete() >
      0;

  @override
  Future<void> forceReleaseLock(String name) =>
      db.table(lockTable, connection: connection).where('key', name).delete();

  @override
  Future<String?> lockOwner(String name) async {
    final row = await db
        .table(lockTable, connection: connection)
        .where('key', name)
        .first();
    if (row == null || ((row['expiration'] as num?)?.toInt() ?? 0) <= _now) {
      return null;
    }
    return row['owner'] as String?;
  }
}
