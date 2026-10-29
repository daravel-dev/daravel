import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;

/// Where sessions are kept (PHP's `SessionHandlerInterface`, as Laravel's
/// handlers implement it). [read] returns the serialized payload, or
/// `null` for a missing or expired session.
abstract interface class SessionHandler {
  Future<String?> read(String id);

  Future<void> write(String id, String payload, {Request? request});

  Future<void> destroy(String id);

  /// Deletes sessions idle for longer than [lifetime].
  Future<void> gc(Duration lifetime);
}

/// One file per session under `storage/framework/sessions`, named by the
/// id and holding the `serialize()` payload: Laravel's `file` driver, so
/// both frameworks on one machine can read each other's files. Expiry is
/// the file's modification time (wall clock, as Laravel reads it).
final class FileSessionHandler implements SessionHandler {
  FileSessionHandler(this.directory, {required this.lifetime});

  final String directory;
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
  DatabaseSessionHandler({
    this.table = 'sessions',
    this.connection,
    required this.lifetime,
  });

  final String table;
  final String? connection;
  final Duration lifetime;

  QueryBuilder get _query => DB.table(table, connection: connection);

  int get _now => Clock.now().millisecondsSinceEpoch ~/ 1000;

  @override
  Future<String?> read(String id) async {
    final row = await _query.where('id', id).first();
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
    final updated = await _query.where('id', id).update(values);
    if (updated == 0) {
      await _query.insert({'id': id, ...values});
    }
  }

  @override
  Future<void> destroy(String id) async {
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

/// Sessions in this isolate's memory: tests and tools. Laravel's `array`
/// driver, which likewise forgets everything when the process ends.
final class ArraySessionHandler implements SessionHandler {
  ArraySessionHandler({required this.lifetime});

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
