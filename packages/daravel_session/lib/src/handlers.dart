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

  /// Deletes sessions idle for longer than [lifetime].
  Future<void> gc(Duration lifetime);
}

/// One file per session under `storage/framework/sessions`, named by the
/// id and holding the `serialize()` payload: Laravel's `file` driver, so
/// both frameworks on one machine can read each other's files. Expiry is
/// the file's modification time (wall clock, as Laravel reads it).
final class FileSessionHandler implements SessionHandler {
  /// Sessions as files in [directory].
  FileSessionHandler(this.directory, {required this.lifetime});

  /// The directory of the session files.
  final String directory;

  /// How long a session lasts.
  final Duration lifetime;

  File _file(String id) => File(p.join(directory, id));

  @override
  Future<String?> read(String id) async {
    final file = _file(id);
    if (!file.existsSync()) {
      return null;
    }
    final modified = file.lastModifiedSync();
    if (DateTime.now().difference(modified) > lifetime) {
      return null;
    }
    return file.readAsString();
  }

  @override
  Future<void> write(String id, String payload, {Request? request}) async {
    final file = _file(id);
    file.parent.createSync(recursive: true);
    await file.writeAsString(payload, flush: true);
  }

  @override
  Future<void> destroy(String id) async {
    final file = _file(id);
    if (file.existsSync()) {
      file.deleteSync();
    }
  }

  @override
  Future<void> gc(Duration lifetime) async {
    final dir = Directory(directory);
    if (!dir.existsSync()) {
      return;
    }
    final cutoff = DateTime.now().subtract(lifetime);
    for (final entry in dir.listSync()) {
      if (entry is File && entry.lastModifiedSync().isBefore(cutoff)) {
        entry.deleteSync();
      }
    }
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
