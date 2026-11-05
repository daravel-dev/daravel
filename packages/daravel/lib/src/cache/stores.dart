import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../foundation/clock.dart';

import 'package:crypto/crypto.dart' as crypto;
import 'package:path/path.dart' as p;

import '../database/database_manager.dart';
import '../database/query/query_builder.dart';
import '../server/coordinator.dart';
import 'cache.dart';
import 'tags.dart';

final class _Entry {
  _Entry(this.value, this.expiresAt);
  Object? value;
  int? expiresAt;
}

/// Bounded LRU store in this isolate's memory (scope `isolate`).
final class MemoryStore implements TouchableCacheStore, TaggableCacheStore {
  /// A store keeping at most [maxEntries] values; [clock] is for tests.
  MemoryStore({this.maxEntries = 10000, DateTime Function()? clock})
    : _clock = clock ?? _utcNow;

  /// The most values kept before the least recently used are dropped.
  final int maxEntries;
  final DateTime Function() _clock;
  final LinkedHashMap<String, _Entry> _entries =
      LinkedHashMap<String, _Entry>();
  final Map<String, ({String owner, int expiresAt})> _locks = {};

  @override
  StateScope get scope => StateScope.isolate;

  @override
  TaggedCacheStore tags(List<String> names, {String prefix = ''}) =>
      TagSetCacheStore(this, names, prefix: prefix);

  /// The number of values held.
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

  /// Locks held or expired but not yet forgotten (see [acquireLockSync]).
  int get lockCount => _locks.length;

  /// Takes the lock [name] for [owner] during [ttl], synchronously.
  bool acquireLockSync(String name, String owner, Duration ttl) {
    final existing = _locks[name];
    if (existing != null &&
        existing.expiresAt > _now &&
        existing.owner != owner) {
      return false;
    }
    if (existing == null && _locks.length >= maxEntries) {
      // A lock that expires without a release (its holder crashed) stayed
      // for ever: with one name per order or user the map only grew. Expired
      // ones are swept once there are as many as cache entries may be.
      final now = _now;
      _locks.removeWhere((_, lock) => lock.expiresAt <= now);
    }
    _locks[name] = (owner: owner, expiresAt: _now + ttl.inMilliseconds);
    return true;
  }

  @override
  Future<bool> releaseLock(String name, String owner) async =>
      releaseLockSync(name, owner);

  /// Releases the lock [name] if [owner] holds it, synchronously.
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

  /// The owner of the lock [name], synchronously.
  String? lockOwnerSync(String name) {
    final existing = _locks[name];
    if (existing == null || existing.expiresAt <= _now) {
      return null;
    }
    return existing.owner;
  }

  /// The value of [key] and the milliseconds it has left (null when it
  /// does not expire), or null when there is none: what
  /// [ProcessStore]'s near cache needs to keep a copy no longer than the
  /// value itself.
  List<Object?>? _withTtl(String key) {
    final entry = _live(key);
    if (entry == null) {
      return null;
    }
    final expiresAt = entry.expiresAt;
    return <Object?>[entry.value, expiresAt == null ? null : expiresAt - _now];
  }

  static DateTime _utcNow() => Clock.now().toUtc();
}

/// Coordinator service exposing a [MemoryStore] to every worker
/// (`process`-scope cache and locks). Values arrive in the wire form of
/// [ProcessStore.encodeWire] (mostly JSON strings) and are kept as they
/// are: this isolate never decodes or copies them.
final class ProcessCacheService
    implements TypedCoordinatorService<LockMessage> {
  /// A service over [store], or a new memory store.
  ProcessCacheService([MemoryStore? store]) : store = store ?? MemoryStore();

  /// The coordinator service name.
  static const String serviceName = 'processCache';

  /// The values every worker shares.
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
      case 'getWithTtl':
        return store._withTtl(key);
      case 'many':
        return store.many((args['keys']! as List<Object?>).cast<String>());
      case 'manyWithTtl':
        return <String, Object?>{
          for (final k in (args['keys']! as List<Object?>).cast<String>())
            k: store._withTtl(k),
        };
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

  /// The lock operations, as [ProcessStore] sends them ([LockMessage]);
  /// [handle] answers them as maps too.
  @override
  Object? handleTyped(LockMessage message) {
    final key = message.key;
    return switch (message.op) {
      'acquireLock' => store.acquireLockSync(
        key,
        message.owner!,
        Duration(milliseconds: message.ttlMs),
      ),
      'releaseLock' => store.releaseLockSync(key, message.owner!),
      'forceReleaseLock' => _forceRelease(key),
      'lockOwner' => store.lockOwnerSync(key),
      final op => throw CoordinatorException(
        'Unknown processCache lock op [$op].',
      ),
    };
  }

  /// [MemoryStore.forceReleaseLock] removes the lock before its first
  /// await, so the answer needs no Future.
  Null _forceRelease(String key) {
    unawaited(store.forceReleaseLock(key));
    return null;
  }

  @override
  Map<String, Object?> stats() => <String, Object?>{'entries': store.size};
}

/// One lock call to [ProcessCacheService], as [ProcessStore] sends it
/// through [TypedCoordinatorChannel.callTyped] (ADR-031): deeply immutable,
/// so it crosses to the coordinator isolate by reference where the map of
/// [toArgs] is copied entry by entry. Other cache operations stay maps.
@pragma('vm:deeply-immutable')
final class LockMessage implements CoordinatorMessage {
  /// A call of [op] on the lock [key].
  const LockMessage(this.op, this.key, {this.owner, this.ttlMs = 0});

  /// `acquireLock`, `releaseLock`, `forceReleaseLock` or `lockOwner`.
  final String op;

  /// The lock's name.
  final String key;

  /// Who takes or releases the lock (`acquireLock`, `releaseLock`).
  final String? owner;

  /// How long an `acquireLock` holds the lock, in milliseconds.
  final int ttlMs;

  /// The same call as the arguments of [ProcessCacheService.handle], for a
  /// channel that is not a [TypedCoordinatorChannel].
  Map<String, Object?> toArgs() => <String, Object?>{
    'key': key,
    if (owner != null) 'owner': owner,
    if (op == 'acquireLock') 'ttl': ttlMs,
  };
}

/// Process-wide cache and locks via the coordinator (scope `process`).
/// Lock calls are **fail-closed**: coordinator errors propagate.
///
/// With [l1Ttl], each isolate keeps the values it reads for that long (up to
/// [l1MaxEntries]) and answers repeated reads without a coordinator round
/// trip; its own writes update or drop them at once, while writes from
/// other isolates show up within [l1Ttl]. Misses, counters and locks always
/// go to the coordinator.
///
/// Values cross to the coordinator as one JSON string (ADR-031): the VM
/// shares a string between the isolates of a process instead of copying
/// it, while a map or list is serialized by the sender, which for a read
/// is the coordinator's single event loop (9 ms per MB, measured). Numbers,
/// booleans and null cross as they are, so `increment` keeps working on a
/// stored number; a value JSON cannot encode (a `DateTime`) crosses as the
/// object it is, copied, as before. The near cache keeps the wire string
/// and decodes it per read, so every caller gets a fresh object.
final class ProcessStore implements TaggableCacheStore {
  /// Values held by the coordinator through [channel], with an optional
  /// per-isolate copy kept for [l1Ttl].
  ProcessStore(
    this.channel, {
    this.timeout = const Duration(seconds: 1),
    this.l1Ttl,
    this.l1MaxEntries = 1000,
  });

  /// The channel to the coordinator.
  final CoordinatorChannel channel;

  /// How long to wait for the coordinator.
  final Duration timeout;

  /// How long a value read is reused in this isolate; null for never.
  final Duration? l1Ttl;

  /// The most values the per-isolate copy keeps.
  final int l1MaxEntries;

  /// Near cache: key → (value, expiry on [_l1Clock] in microseconds). A
  /// monotonic clock: staleness is wall time, not `Clock` (tests may freeze
  /// domain time).
  final Map<String, (Object?, int)> _l1 = <String, (Object?, int)>{};
  final Stopwatch _l1Clock = Stopwatch()..start();

  @override
  StateScope get scope => StateScope.process;

  @override
  TaggedCacheStore tags(List<String> names, {String prefix = ''}) =>
      TagSetCacheStore(this, names, prefix: prefix);

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
    return decodeWire(entry.$1);
  }

  /// Keeps the wire form of a value (a string, a number...) for [l1Ttl],
  /// or for [left] when the value itself expires sooner: the near cache
  /// never serves a value the coordinator has already forgotten.
  void _l1Write(String key, Object? wire, [Duration? left]) {
    var ttl = l1Ttl;
    _l1.remove(key);
    if (ttl == null || wire == null) {
      return;
    }
    if (left != null && left < ttl) {
      if (left <= Duration.zero) {
        return;
      }
      ttl = left;
    }
    if (_l1.length >= l1MaxEntries) {
      _l1.remove(_l1.keys.first); // Oldest first (insertion order).
    }
    _l1[key] = (wire, _l1Clock.elapsedMicroseconds + ttl.inMicroseconds);
  }

  /// The form in which [value] crosses to the coordinator: numbers,
  /// booleans and null as they are, anything else as a JSON string (shared
  /// between isolates, not copied), or the object itself when JSON cannot
  /// encode it. Exposed for tests and benchmarks.
  static Object? encodeWire(Object? value) {
    switch (value) {
      case null || num() || bool():
        return value;
      default:
        try {
          return jsonEncode(value);
        } on JsonUnsupportedObjectError {
          return value;
        }
    }
  }

  /// The value a wire form from [encodeWire] stands for: a string is JSON
  /// and decodes to a fresh object; anything else is returned as it is.
  static Object? decodeWire(Object? wire) =>
      wire is String ? jsonDecode(wire) : wire;

  @override
  Future<Object?> get(String key) async {
    if (l1Ttl != null) {
      final cached = _l1Read(key);
      if (cached != null) {
        return cached;
      }
    }
    if (l1Ttl == null) {
      return decodeWire(await _call('get', {'key': key}));
    }
    return decodeWire(_l1Entry(key, await _call('getWithTtl', {'key': key})));
  }

  /// Keeps an answer of `getWithTtl` (the value and the milliseconds it
  /// has left, or null) in the near cache and returns its wire form.
  Object? _l1Entry(String key, Object? entry) {
    if (entry is! List<Object?>) {
      _l1.remove(key);
      return null;
    }
    final wire = entry[0];
    final leftMs = entry[1] as int?;
    _l1Write(key, wire, leftMs == null ? null : Duration(milliseconds: leftMs));
    return wire;
  }

  @override
  Future<Map<String, Object?>> many(List<String> keys) async {
    final Map<String, Object?> wires;
    if (l1Ttl == null) {
      wires = (await _call('many', {'keys': keys}))! as Map<String, Object?>;
    } else {
      final entries =
          (await _call('manyWithTtl', {'keys': keys}))! as Map<String, Object?>;
      wires = <String, Object?>{
        for (final MapEntry(:key, :value) in entries.entries)
          key: _l1Entry(key, value),
      };
    }
    return <String, Object?>{
      for (final MapEntry(:key, :value) in wires.entries)
        key: decodeWire(value),
    };
  }

  @override
  Future<void> put(String key, Object? value, {Duration? ttl}) async {
    _l1.remove(key);
    final wire = encodeWire(value);
    await _call('put', {'key': key, 'value': wire, 'ttl': ttl?.inMilliseconds});
    _l1Write(key, wire, ttl);
  }

  @override
  Future<void> putMany(Map<String, Object?> values, {Duration? ttl}) async {
    values.keys.forEach(_l1.remove);
    final wires = <String, Object?>{
      for (final MapEntry(:key, :value) in values.entries)
        key: encodeWire(value),
    };
    await _call('putMany', {'values': wires, 'ttl': ttl?.inMilliseconds});
    wires.forEach((key, wire) => _l1Write(key, wire, ttl));
  }

  @override
  Future<bool> add(String key, Object? value, {Duration? ttl}) async {
    _l1.remove(key);
    return await _call('add', {
      'key': key,
      'value': encodeWire(value),
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

  /// Sends a lock call typed, or as a map to a channel that is only a
  /// [CoordinatorChannel].
  Future<Object?> _lock(LockMessage message, {Duration? wait}) {
    final target = channel;
    return target is TypedCoordinatorChannel
        ? target.callTyped(
            ProcessCacheService.serviceName,
            message,
            timeout: wait ?? timeout,
          )
        : target.call(
            ProcessCacheService.serviceName,
            message.op,
            message.toArgs(),
            timeout: wait ?? timeout,
          );
  }

  /// How long the release sent after a timed-out [acquireLock] may take.
  static const Duration lostAcquireReleaseTimeout = Duration(seconds: 30);

  /// Takes the lock, or throws when the coordinator does not answer.
  ///
  /// When the answer times out the coordinator may still have given the
  /// lock to [owner], which nobody would then release before [ttl] ends: a
  /// release for [owner] follows at once (the coordinator answers a worker's
  /// messages in order, so it comes after the acquire, and it is a no-op
  /// when the lock is someone else's) before the timeout is rethrown.
  @override
  Future<bool> acquireLock(String name, String owner, Duration ttl) async {
    try {
      return await _lock(
        LockMessage(
          'acquireLock',
          name,
          owner: owner,
          ttlMs: ttl.inMilliseconds,
        ),
      ) as bool;
    } on CoordinatorTimeoutException {
      unawaited(
        _lock(
          LockMessage('releaseLock', name, owner: owner),
          wait: lostAcquireReleaseTimeout,
        ).then<void>((_) {}, onError: (Object _) {}),
      );
      rethrow;
    }
  }

  @override
  Future<bool> releaseLock(String name, String owner) async =>
      await _lock(LockMessage('releaseLock', name, owner: owner)) as bool;

  @override
  Future<void> forceReleaseLock(String name) =>
      _lock(LockMessage('forceReleaseLock', name));

  @override
  Future<String?> lockOwner(String name) async =>
      await _lock(LockMessage('lockOwner', name)) as String?;
}

/// JSON files under a directory (scope `cluster` on a shared disk, otherwise
/// `process`). Writes go to a temp file then `rename` (atomic on POSIX and
/// NTFS). Locks use exclusive file creation.
final class FileStore implements TouchableCacheStore {
  /// A store of one file per key in [directory].
  FileStore(this.directory);

  /// The directory holding the files.
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

  /// Writes are atomic across processes: the payload goes to a temporary
  /// file of its own (process, isolate and call are all in its name) that
  /// then replaces the entry by a rename, so a reader sees the old file or
  /// the new one, never a partial write (Laravel writes with `LOCK_EX`).
  /// When another process removed the directory in between (a `flush`), the
  /// write is made again.
  Future<void> _write(String key, Object? value, Duration? ttl) async {
    final file = File(_path(key));
    final payload = jsonEncode(<String, Object?>{
      'e': ttl == null ? null : _now + ttl.inMilliseconds,
      'v': value,
    });
    for (var attempt = 1; ; attempt++) {
      final temp = File('${file.path}.${_tempSuffix()}.tmp');
      try {
        await file.parent.create(recursive: true);
        await temp.writeAsString(payload, flush: true);
        await _replace(temp, file);
        return;
      } on FileSystemException {
        await _delete(temp);
        if (attempt >= _attempts) {
          rethrow;
        }
      }
    }
  }

  /// Renames [temp] over [target]. Windows refuses the rename for a moment
  /// (`ERROR_ACCESS_DENIED` or `ERROR_SHARING_VIOLATION`) while another
  /// writer is replacing the same entry or a reader has it open, so there it
  /// is tried again with a backoff, keeping the temporary file. Any other
  /// failure, or a temporary file a `flush` removed, goes to the caller.
  static Future<void> _replace(File temp, File target) async {
    // A Stopwatch, not Clock.now(): a test that freezes the clock still
    // gives up.
    final waited = Stopwatch()..start();
    for (var wait = 1; ; wait = min(wait * 2, 20)) {
      try {
        await temp.rename(target.path);
        return;
      } on FileSystemException catch (e) {
        final code = e.osError?.errorCode;
        if (!Platform.isWindows ||
            (code != 5 && code != 32) ||
            waited.elapsed > _replaceTimeout ||
            !await temp.exists()) {
          rethrow;
        }
      }
      await Future<void>.delayed(Duration(milliseconds: wait));
    }
  }

  static const Duration _replaceTimeout = Duration(seconds: 5);

  static const int _attempts = 5;
  static final Random _random = Random();
  static int _tempSequence = 0;

  static String _tempSuffix() =>
      '${pid}_${_random.nextInt(1 << 32).toRadixString(16)}_'
      '${_tempSequence++}';

  /// The last read-modify-write update queued per key in this isolate.
  final Map<String, Completer<void>> _queued = <String, Completer<void>>{};

  /// Runs [body] holding the key's mutex: an exclusive OS lock on a file in
  /// `<directory>/mutex` keeps other processes out, and a queue keeps the
  /// other calls of this isolate out (an OS lock belongs to the process).
  Future<T> _exclusive<T>(String key, Future<T> Function() body) async {
    final previous = _queued[key];
    final done = Completer<void>();
    _queued[key] = done;
    try {
      if (previous != null) {
        await previous.future;
      }
      return await _locked(key, body);
    } finally {
      done.complete();
      if (identical(_queued[key], done)) {
        _queued.remove(key);
      }
    }
  }

  /// Polls a non-blocking lock: a blocking one parks a thread per waiting
  /// key, and the kernel reports a deadlock (EDEADLK) when two processes
  /// each wait for a key the other holds, although each call holds only one.
  static Future<void> _lock(RandomAccessFile handle) async {
    // A Stopwatch, not Clock.now(): a test that freezes the clock still
    // gives up.
    final waited = Stopwatch()..start();
    for (var wait = 1; ; wait = min(wait * 2, 20)) {
      try {
        await handle.lock(FileLock.exclusive);
        return;
      } on FileSystemException {
        if (waited.elapsed > _lockTimeout) {
          rethrow;
        }
      }
      await Future<void>.delayed(Duration(milliseconds: wait));
    }
  }

  static const Duration _lockTimeout = Duration(seconds: 30);

  Future<T> _locked<T>(String key, Future<T> Function() body) async {
    final hash = crypto.sha1.convert(utf8.encode(key)).toString();
    final file = File(p.join(directory, 'mutex', '$hash.lock'));
    RandomAccessFile? handle;
    for (var attempt = 1; handle == null; attempt++) {
      try {
        await file.parent.create(recursive: true);
        handle = await file.open(mode: FileMode.append);
      } on FileSystemException {
        if (attempt >= _attempts) {
          rethrow;
        }
      }
    }
    try {
      await _lock(handle);
      return await body();
    } finally {
      try {
        await handle.unlock();
      } on FileSystemException {
        // Closing the handle releases the lock as well.
      }
      await handle.close();
    }
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
  Future<bool> touch(String key, Duration ttl) => _exclusive(key, () async {
    final entry = await _read(key);
    if (entry == null) {
      return false;
    }
    await _write(key, entry['v'], ttl);
    return true;
  });

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

  /// Atomic across processes and the calls of this isolate, like Laravel's
  /// `FileStore::add` under an exclusive lock.
  @override
  Future<bool> add(String key, Object? value, {Duration? ttl}) =>
      _exclusive(key, () async {
        if (await _read(key) != null) {
          return false;
        }
        await _write(key, value, ttl);
        return true;
      });

  /// Atomic across processes and the calls of this isolate: no increment is
  /// lost to one made at the same time.
  @override
  Future<int> increment(String key, [int by = 1]) => _exclusive(key, () async {
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
  });

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
    // Another process can remove the directory, or write into it, while it
    // is deleted: the delete is made again until the directory is gone.
    for (var attempt = 1; await dir.exists(); attempt++) {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        if (attempt >= _attempts) {
          rethrow;
        }
      }
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
  /// A store in the [table] (`cache`) of [db], shared with Laravel's
  /// database cache.
  DatabaseStore(
    this.db, {
    this.table = 'cache',
    this.lockTable = 'cache_locks',
    this.connection,
  });

  /// The database holding the values.
  final DatabaseManager db;

  /// The cache table.
  final String table;

  /// The locks table.
  final String lockTable;

  /// The connection of the tables; the default one when null.
  final String? connection;

  /// Laravel's `DatabaseStore::forever` puts the value for ten years
  /// (315 360 000 s): a relative time that fits the `integer` column of its
  /// `cache` table on MySQL and MariaDB, where a far-future constant would
  /// overflow (2038).
  static const int foreverTtlSeconds = 315360000;

  /// The `expiration` written by [forever] right now.
  static int get foreverExpiration => _now + foreverTtlSeconds;

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

  /// A value this store wrote, or null. Laravel can share the table: its
  /// `serialize()` text and plain integers are misses here, not errors.
  static Object? _decode(Object? raw) {
    if (raw is! String) {
      return null;
    }
    try {
      return switch (jsonDecode(raw)) {
        final Map<String, Object?> entry => entry['v'],
        _ => null,
      };
    } on FormatException {
      return null;
    }
  }

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
      .mysql || .mariadb => ('SIGNED', 'CHAR'),
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
    final upsert = dialect.isMySqlFamily
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
