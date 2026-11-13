import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;

/// Where sessions are kept (PHP's `SessionHandlerInterface`, as Laravel's
/// handlers implement it). [read] returns the serialized payload, or
/// `null` for a missing or expired session.
abstract interface class SessionHandler {
  /// The payload of session [id], or null.
  Future<String?> read(String id);

  /// Stores [payload] as session [id].
  Future<void> write(String id, String payload, {Request? request});

  /// Deletes session [id].
  Future<void> destroy(String id);

  /// Deletes sessions idle for longer than [lifetime]. The session
  /// middleware awaits it in the request that wins the lottery, inside that
  /// request's zone and transaction, as Laravel's `StartSession` does; a
  /// handler that is also [SweepsInRounds] is swept outside the request
  /// instead ([SessionGarbageCollector]).
  Future<void> gc(Duration lifetime);
}

/// A [SessionHandler] whose [SessionHandler.gc] does a bounded part of the
/// sweep per call and holds no database connection, so the session
/// middleware runs it detached from the request ([SessionGarbageCollector])
/// instead of making the request wait.
///
/// A handler whose sweep is one query (the `database`, `cache` and `redis`
/// drivers) is not one: run detached, its `DELETE` would leave the request's
/// transaction, which under `refreshDatabase` deletes rows committed
/// outside the test and, on MySQL, waits for the test's row locks.
abstract interface class SweepsInRounds implements SessionHandler {}

/// One file per session under `storage/framework/sessions`, named by the
/// id and holding the `serialize()` payload: Laravel's `file` driver, so
/// both frameworks on one machine can read each other's files.
///
/// Expiry compares the file's modification time, which the file system
/// stamps with the wall clock, with `Clock.now()`, as Laravel compares it
/// with `Carbon::now()`: in tests `travel()` forward ages the files without
/// waiting, and a clock moved back makes them younger, never expired.
final class FileSessionHandler implements SweepsInRounds {
  /// Sessions as files in [directory]. Each [gc] call examines at most
  /// [gcBatch] files or runs for at most [gcBudget], then stops; the next
  /// call resumes where it stopped. [gcBatch] must be at least 1.
  FileSessionHandler(
    this.directory, {
    required this.lifetime,
    this.gcBatch = 2000,
    this.gcBudget = const Duration(milliseconds: 250),
  }) {
    if (gcBatch < 1) {
      throw ArgumentError.value(gcBatch, 'gcBatch', 'must be at least 1');
    }
  }

  /// The directory of the session files.
  final String directory;

  /// How long a session lasts.
  final Duration lifetime;

  /// The files one [gc] call examines at most.
  final int gcBatch;

  /// How long one [gc] call examines files at most (wall clock).
  final Duration gcBudget;

  /// Where the next [gc] call resumes: the number of directory entries it
  /// skips first. Back to 0 once a call reached the end.
  int get gcPosition => _gcPosition;
  int _gcPosition = 0;

  File _file(String id) => File(p.join(directory, id));

  /// The session, or null when its file is missing, expired, or deleted
  /// while being read (a sweep in another isolate or process, or Laravel's).
  @override
  Future<String?> read(String id) async {
    final file = _file(id);
    try {
      final modified = await file.lastModified();
      if (Clock.now().difference(modified) > lifetime) {
        return null;
      }
      return await file.readAsString();
    } on FileSystemException catch (error) {
      if (await _goneOrGoing(file, error)) {
        return null;
      }
      rethrow;
    }
  }

  @override
  Future<void> write(String id, String payload, {Request? request}) async {
    final file = _file(id);
    file.parent.createSync(recursive: true);
    await file.writeAsString(payload, flush: true);
  }

  /// Deletes the session's file; one that is gone already, or being deleted
  /// by a sweep elsewhere, is done (as Laravel's `Filesystem::delete`).
  @override
  Future<void> destroy(String id) async {
    final file = _file(id);
    try {
      await file.delete();
    } on FileSystemException catch (error) {
      if (!await _goneOrGoing(file, error)) {
        rethrow;
      }
    }
  }

  /// Whether [error] on [file] means the file is gone or going: not found,
  /// or refused while another isolate or process deletes it (Windows
  /// refuses access to a file whose deletion is pending), which shows as
  /// the file disappearing within a few milliseconds. Access refused on a
  /// file that stays is an error.
  static Future<bool> _goneOrGoing(File file, FileSystemException error) async {
    if (error is PathNotFoundException) {
      return true;
    }
    if (error is! PathAccessException) {
      return false;
    }
    for (var i = 0; i < 20; i++) {
      if (!await file.exists()) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    return false;
  }

  /// One bounded round: skips the [gcPosition] entries examined before,
  /// then deletes the expired files among the next [gcBatch] (or as many as
  /// [gcBudget] allows), all asynchronously, so a directory of many files
  /// never holds the event loop. A round that reaches the end of the
  /// listing starts the next one from the beginning; files deleted meanwhile
  /// by another process or isolate are skipped. Files that others delete
  /// ahead of the resume position move the listing up, so some expired
  /// files are reached only on the next pass. Names starting with `.`
  /// (`.gitignore`, `.gitkeep`) are never deleted, as Laravel's
  /// `ignoreDotFiles(true)`.
  @override
  Future<void> gc(Duration lifetime) async {
    final dir = Directory(directory);
    if (!await dir.exists()) {
      _gcPosition = 0;
      return;
    }
    final cutoff = Clock.now().subtract(lifetime);
    final watch = Stopwatch();
    var skipped = 0;
    var examined = 0;
    var deleted = 0;
    var reachedEnd = true;
    // Breaking out of `await for` cancels the listing, which releases the
    // directory handle (Windows refuses to delete a directory being read).
    await for (final entry in dir.list(followLinks: false)) {
      if (skipped < _gcPosition) {
        skipped++;
        continue;
      }
      watch.start();
      if (examined >= gcBatch || (examined > 0 && watch.elapsed >= gcBudget)) {
        reachedEnd = false;
        break;
      }
      examined++;
      if (entry is! File || p.basename(entry.path).startsWith('.')) {
        continue;
      }
      try {
        final stat = await entry.stat();
        if (stat.type == FileSystemEntityType.file &&
            stat.modified.isBefore(cutoff)) {
          await entry.delete();
          deleted++;
        }
      } on FileSystemException {
        // Gone already (another isolate or Laravel swept it) or locked.
      }
    }
    // The deleted files left the listing: the entries after them moved up.
    _gcPosition = reachedEnd ? 0 : skipped + examined - deleted;
  }
}

/// Laravel's `sessions` table (`id`, `user_id`, `ip_address`,
/// `user_agent`, `payload`, `last_activity`): the payload is the
/// `serialize()` text in base64 and `last_activity` a Unix timestamp, so
/// a Laravel application on the same database shares the sessions.
final class DatabaseSessionHandler implements SessionHandler {
  /// Sessions in the `sessions` table, shared with Laravel.
  DatabaseSessionHandler({
    this.table = 'sessions',
    this.connection,
    required this.lifetime,
  });

  /// The sessions table.
  final String table;

  /// The connection of the table; the default one when null.
  final String? connection;

  /// How long a session lasts.
  final Duration lifetime;

  QueryBuilder get _query => DB.table(table, connection: connection);

  int get _now => Clock.now().millisecondsSinceEpoch ~/ 1000;

  /// Whether [read] found a row, per session id, until the [write] of the
  /// same request (Laravel's `$exists`; one handler serves every request
  /// of the isolate, so it is kept per id rather than per instance).
  final Map<String, bool> _exists = {};

  /// How many ids [_exists] keeps for reads that no write followed (a
  /// request that failed before saving). The oldest go first; a write
  /// whose id was dropped looks the row up again.
  static const int _maxRemembered = 10000;

  @override
  Future<String?> read(String id) async {
    final row = await _query.where('id', id).first();
    _remember(id, exists: row != null);
    if (row == null) {
      return null;
    }
    final lastActivity = _int(row['last_activity']);
    if (lastActivity != null && lastActivity < _now - lifetime.inSeconds) {
      return null;
    }
    final payload = row['payload'];
    if (payload == null) {
      return null;
    }
    return utf8.decode(base64.decode('$payload'));
  }

  /// Updates the row when it exists and inserts it otherwise, as Laravel's
  /// `DatabaseSessionHandler::write` does. The row count of an UPDATE
  /// cannot decide it: MySQL and MariaDB count changed rows, so an
  /// unchanged payload in the same second reports 0 for a row that exists.
  @override
  Future<void> write(String id, String payload, {Request? request}) async {
    final values = <String, Object?>{
      'payload': base64.encode(utf8.encode(payload)),
      'last_activity': _now,
      'user_id': await _userId(),
      if (request != null) ...{
        'ip_address': request.ip,
        'user_agent': _cut(request.header('user-agent'), 500),
      },
    };
    final exists = _exists.remove(id) ?? await _query.where('id', id).exists();
    if (exists) {
      await _query.where('id', id).update(values);
      return;
    }
    try {
      await _query.insert({'id': id, ...values});
    } on UniqueConstraintViolationException {
      // Another request created the row after this one read it
      // (Laravel's performInsert falls back to performUpdate likewise).
      await _query.where('id', id).update(values);
    }
  }

  void _remember(String id, {required bool exists}) {
    _exists.remove(id);
    if (_exists.length >= _maxRemembered) {
      _exists.remove(_exists.keys.first);
    }
    _exists[id] = exists;
  }

  @override
  Future<void> destroy(String id) async {
    _exists.remove(id);
    await _query.where('id', id).delete();
  }

  @override
  Future<void> gc(Duration lifetime) async {
    await _query
        .where('last_activity', '<=', _now - lifetime.inSeconds)
        .delete();
  }

  /// The authenticated user's id (Laravel's `Guard::id()`), `null` without
  /// a guard or a user.
  Future<Object?> _userId() async {
    final auth = Container.current.tryMake<AuthManager>();
    if (auth == null) {
      return null;
    }
    try {
      return await auth.id();
    } on Object {
      return null;
    }
  }

  static int? _int(Object? value) => switch (value) {
    final int v => v,
    final num v => v.toInt(),
    final String v => int.tryParse(v),
    _ => null,
  };

  static String? _cut(String? value, int length) =>
      value == null || value.length <= length
      ? value
      : value.substring(0, length);
}

/// Sessions in a cache store, Laravel's `CacheBasedSessionHandler`: the
/// payload is the value under the session id (after the store's and the
/// repository's prefixes) and expires after [lifetime], renewed by every
/// write. The `cache` driver uses the store `SESSION_STORE` names;
/// `daravel_redis` builds the `redis` driver on it with Laravel's key
/// layout.
final class CacheSessionHandler implements SessionHandler {
  /// Sessions in [cache], each kept for [lifetime] after its last write.
  CacheSessionHandler(this.cache, {required this.lifetime});

  /// The cache holding the sessions.
  final CacheRepository cache;

  /// How long a session lasts (the entry's TTL).
  final Duration lifetime;

  @override
  Future<String?> read(String id) async {
    final value = await cache.get<Object>(id);
    return value is String ? value : null;
  }

  @override
  Future<void> write(String id, String payload, {Request? request}) =>
      cache.put(id, payload, ttl: lifetime);

  @override
  Future<void> destroy(String id) async {
    await cache.forget(id);
  }

  /// Nothing to do: the store expires sessions (Laravel returns 0).
  @override
  Future<void> gc(Duration lifetime) async {}
}

/// Sessions in this isolate's memory: tests and tools. Laravel's `array`
/// driver, which likewise forgets everything when the process ends.
final class ArraySessionHandler implements SessionHandler {
  /// Sessions in memory, for tests.
  ArraySessionHandler({required this.lifetime});

  /// How long a session lasts.
  final Duration lifetime;
  final Map<String, (String, DateTime)> _sessions = {};

  /// The payloads held right now, by id (for assertions).
  Map<String, String> get payloads => {
    for (final entry in _sessions.entries) entry.key: entry.value.$1,
  };

  @override
  Future<String?> read(String id) async {
    final entry = _sessions[id];
    if (entry == null) {
      return null;
    }
    if (Clock.now().difference(entry.$2) > lifetime) {
      _sessions.remove(id);
      return null;
    }
    return entry.$1;
  }

  @override
  Future<void> write(String id, String payload, {Request? request}) async {
    _sessions[id] = (payload, Clock.now());
  }

  @override
  Future<void> destroy(String id) async {
    _sessions.remove(id);
  }

  @override
  Future<void> gc(Duration lifetime) async {
    final cutoff = Clock.now().subtract(lifetime);
    _sessions.removeWhere((_, entry) => entry.$2.isBefore(cutoff));
  }
}
