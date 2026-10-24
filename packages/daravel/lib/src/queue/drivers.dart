import 'dart:async';
import 'dart:convert';

import '../foundation/clock.dart';

import 'package:uuid/uuid.dart';

import '../database/database_manager.dart';
import '../database/query/query_builder.dart';
import '../database/schema/migration.dart';
import '../database/schema/schema_builder.dart';
import '../server/coordinator.dart';
import 'job.dart';

/// JSON envelope stored by every driver. Top-level keys mirror Laravel's
/// payload (`uuid`, `displayName`, `job`, `maxTries`, …); `data` holds the
/// Dart job's own JSON, so payloads are not cross-runtime (§4.4).
final class JobPayload {
  const JobPayload({
    required this.uuid,
    required this.jobName,
    required this.displayName,
    required this.data,
    required this.maxTries,
    required this.maxExceptions,
    required this.failOnTimeout,
    required this.backoffSeconds,
    required this.timeout,
    required this.pushedAt,
    this.retryUntil,
    this.uniqueKey,
    this.tags = const <String>[],
  });

  factory JobPayload.forJob(
    Job job, {
    String? uuid,
    DateTime? now,
    String? uniqueKey,
  }) {
    final pushed = (now ?? Clock.now().toUtc()).millisecondsSinceEpoch ~/ 1000;
    final retryUntil = job.retryUntil;
    return JobPayload(
      uuid: uuid ?? const Uuid().v4(),
      jobName: job.jobName,
      displayName: job.displayName,
      data: job.toJson(),
      maxTries: job.tries,
      maxExceptions: job.maxExceptions,
      failOnTimeout: job.failOnTimeout,
      backoffSeconds: [for (final d in job.backoff) d.inSeconds],
      timeout: job.timeout,
      pushedAt: pushed,
      retryUntil: retryUntil == null ? null : pushed + retryUntil.inSeconds,
      uniqueKey: uniqueKey,
      tags: List.unmodifiable(job.tags),
    );
  }

  factory JobPayload.fromJson(Map<String, Object?> json) => JobPayload(
    uuid: json['uuid'] as String,
    jobName: json['job'] as String,
    displayName: json['displayName'] as String? ?? json['job'] as String,
    data: (json['data'] as Map<String, Object?>?) ?? const {},
    maxTries: (json['maxTries'] as num?)?.toInt() ?? 1,
    maxExceptions: (json['maxExceptions'] as num?)?.toInt() ?? 1,
    failOnTimeout: json['failOnTimeout'] as bool? ?? false,
    backoffSeconds: _backoff(json['backoff']),
    timeout: Duration(
      milliseconds: (((json['timeout'] as num?) ?? 60) * 1000).round(),
    ),
    pushedAt: (json['pushedAt'] as num?)?.toInt() ?? 0,
    retryUntil: (json['retryUntil'] as num?)?.toInt(),
    uniqueKey: json['uniqueKey'] as String?,
    tags: [
      for (final tag in (json['tags'] as List<Object?>?) ?? const <Object?>[])
        if (tag is String) tag,
    ],
  );

  /// Backoff seconds as a list (Daravel), a number, or Laravel's
  /// comma-separated string (`"1,5,10"`).
  static List<int> _backoff(Object? value) => switch (value) {
    final List<Object?> list => [for (final e in list) (e! as num).toInt()],
    final num seconds => [seconds.toInt()],
    final String csv when csv.trim().isNotEmpty => [
      for (final part in csv.split(',')) int.tryParse(part.trim()) ?? 0,
    ],
    _ => const <int>[],
  };

  /// Parses the stored JSON string.
  factory JobPayload.decode(String raw) =>
      JobPayload.fromJson(jsonDecode(raw) as Map<String, Object?>);

  final String uuid;
  final String jobName;
  final String displayName;
  final Map<String, Object?> data;
  final int maxTries;
  final int maxExceptions;
  final bool failOnTimeout;
  final List<int> backoffSeconds;

  /// Handler timeout (stored as seconds, fractional for sub-second).
  final Duration timeout;

  /// Epoch seconds of the first push.
  final int pushedAt;

  /// Epoch seconds after which no retry happens (`null` = use maxTries).
  final int? retryUntil;

  /// Unique-job lock key to release after processing.
  final String? uniqueKey;

  /// Monitoring tags ([Job.tags]; Laravel Horizon's `tags` payload key).
  final List<String> tags;

  Map<String, Object?> toJson() => <String, Object?>{
    'uuid': uuid,
    'displayName': displayName,
    'job': jobName,
    'maxTries': maxTries,
    'maxExceptions': maxExceptions,
    'failOnTimeout': failOnTimeout,
    'backoff': backoffSeconds,
    'timeout': timeout.inMilliseconds / 1000,
    'retryUntil': retryUntil,
    'pushedAt': pushedAt,
    'uniqueKey': uniqueKey,
    'tags': tags,
    'data': data,
  };

  String encode() => jsonEncode(toJson());
}

/// A reserved job handed to the worker.
final class QueuedJob {
  const QueuedJob({
    required this.id,
    required this.queue,
    required this.payload,
    required this.attempts,
    required this.raw,
  });

  final Object id;
  final String queue;
  final JobPayload payload;

  /// Attempts including the current one.
  final int attempts;

  /// Stored JSON (for `failed_jobs`).
  final String raw;
}

/// Queue backend (BLUEPRINT_V2 §7.9.1).
abstract interface class QueueDriver {
  String get name;

  StateScope get scope;

  /// Stores [payload]; returns the driver's job id.
  Future<Object> push(
    JobPayload payload, {
    required String queue,
    Duration? delay,
  });

  /// Reserves the next available job on [queue] (`null` when empty).
  Future<QueuedJob?> pop(String queue);

  /// Puts a reserved job back, available after [delay].
  Future<void> release(QueuedJob job, Duration delay);

  Future<void> delete(QueuedJob job);

  Future<int> size(String queue);

  /// How long the oldest job that is ready to run on [queue] has been
  /// waiting (`null` when none is waiting). Used by queue dashboards and
  /// auto-scaling (Laravel Horizon's "wait time").
  Future<Duration?> oldestWait(String queue);

  Future<int> clear(String queue);
}

final class _MemoryEntry {
  _MemoryEntry(this.id, this.queue, this.payload, this.availableAt);

  final int id;
  final String queue;
  final JobPayload payload;
  int availableAt;
  int attempts = 0;
  bool reserved = false;
}

/// In-memory queue (scope `isolate`): tests and `--embed-queue` style
/// single-process setups.
final class MemoryQueue implements QueueDriver {
  MemoryQueue({DateTime Function()? clock}) : _clock = clock ?? _utcNow;

  final DateTime Function() _clock;
  final List<_MemoryEntry> _entries = <_MemoryEntry>[];
  int _nextId = 0;

  @override
  String get name => 'memory';

  @override
  StateScope get scope => StateScope.isolate;

  int get _now => _clock().millisecondsSinceEpoch;

  @override
  Future<Object> push(
    JobPayload payload, {
    required String queue,
    Duration? delay,
  }) async {
    final id = ++_nextId;
    _entries.add(
      _MemoryEntry(id, queue, payload, _now + (delay?.inMilliseconds ?? 0)),
    );
    return id;
  }

  @override
  Future<QueuedJob?> pop(String queue) async {
    final now = _now;
    for (final entry in _entries) {
      if (entry.queue == queue && !entry.reserved && entry.availableAt <= now) {
        entry
          ..reserved = true
          ..attempts += 1;
        return QueuedJob(
          id: entry.id,
          queue: queue,
          payload: entry.payload,
          attempts: entry.attempts,
          raw: entry.payload.encode(),
        );
      }
    }
    return null;
  }

  @override
  Future<void> release(QueuedJob job, Duration delay) async {
    for (final entry in _entries) {
      if (entry.id == job.id) {
        entry
          ..reserved = false
          ..availableAt = _now + delay.inMilliseconds;
      }
    }
  }

  @override
  Future<void> delete(QueuedJob job) async =>
      _entries.removeWhere((e) => e.id == job.id);

  @override
  Future<int> size(String queue) async =>
      _entries.where((e) => e.queue == queue).length;

  @override
  Future<Duration?> oldestWait(String queue) async {
    final now = _now;
    int? oldest;
    for (final entry in _entries) {
      if (entry.queue == queue &&
          !entry.reserved &&
          entry.availableAt <= now &&
          (oldest == null || entry.availableAt < oldest)) {
        oldest = entry.availableAt;
      }
    }
    return oldest == null ? null : Duration(milliseconds: now - oldest);
  }

  @override
  Future<int> clear(String queue) async {
    final before = _entries.length;
    _entries.removeWhere((e) => e.queue == queue);
    return before - _entries.length;
  }

  static DateTime _utcNow() => Clock.now().toUtc();
}

/// Laravel-compatible `jobs` table (scope `cluster`). Reservation is an
/// optimistic `UPDATE … WHERE reserved_at IS NULL`, so several workers
/// never process the same row twice.
final class DatabaseQueue implements QueueDriver {
  DatabaseQueue(
    this.db, {
    this.table = 'jobs',
    this.connection,
    this.retryAfter = const Duration(seconds: 90),
    this.onForeignJob,
    DateTime Function()? clock,
  }) : _clock = clock ?? _utcNow;

  final DatabaseManager db;
  final String table;
  final String? connection;

  /// Reserved jobs older than this are considered abandoned and re-queued.
  final Duration retryAfter;

  /// Called once per foreign job (pushed by a Laravel app sharing the
  /// `jobs` table) that this worker skipped; see [isForeignPayload].
  final void Function(String queue, Object id, String handler)? onForeignJob;
  final DateTime Function() _clock;

  /// Foreign job ids seen per queue, excluded from later polls so they never
  /// hide Daravel jobs queued behind them. Bounded; oldest ids drop first.
  final Map<String, Set<Object>> _foreign = <String, Set<Object>>{};
  static const int _maxForeignIds = 1000;

  /// Rows read per poll while looking past foreign jobs.
  static const int _pollBatch = 16;

  /// Whether [raw] was pushed by Laravel rather than Daravel. Laravel's
  /// payloads are JSON too, but their `job` is a PHP handler such as
  /// `Illuminate\Queue\CallQueuedHandler@call` and `data` holds a
  /// PHP-serialized `command`; Daravel job names never contain `\` or `@`.
  /// Anything that is not a JSON object is foreign as well.
  static bool isForeignPayload(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException {
      return true;
    }
    if (decoded is! Map<String, Object?>) {
      return true;
    }
    final job = decoded['job'];
    if (job is! String || job.contains(r'\') || job.contains('@')) {
      return true;
    }
    final data = decoded['data'];
    return data is Map<String, Object?> &&
        (data.containsKey('commandName') || data['command'] is String);
  }

  @override
  String get name => 'database';

  @override
  StateScope get scope => StateScope.cluster;

  int get _now => _clock().millisecondsSinceEpoch ~/ 1000;

  QueryBuilder _query() => db.table(table, connection: connection);

  @override
  Future<Object> push(
    JobPayload payload, {
    required String queue,
    Duration? delay,
  }) async {
    final now = _now;
    final id = await _query().insertGetId(<String, Object?>{
      'queue': queue,
      'payload': payload.encode(),
      'attempts': 0,
      'reserved_at': null,
      'available_at': now + (delay?.inSeconds ?? 0),
      'created_at': now,
    });
    return id!;
  }

  /// Claims the next available Daravel job of [queue].
  ///
  /// Jobs pushed by a Laravel app sharing the table are skipped without being
  /// touched (no `reserved_at`, no `attempts` change), so Laravel's workers
  /// still process them normally.
  @override
  Future<QueuedJob?> pop(String queue) async {
    for (var attempt = 0; attempt < 5; attempt++) {
      final now = _now;
      final stale = now - retryAfter.inSeconds;
      final skip = _foreign[queue] ?? const <Object>{};
      final query = _query().where('queue', queue).where((QueryBuilder q) {
        q
            .where((QueryBuilder available) {
              available
                  .whereNull('reserved_at')
                  .where('available_at', '<=', now);
            })
            .orWhere('reserved_at', '<=', stale);
      });
      if (skip.isNotEmpty) {
        query.whereNotIn('id', skip.toList());
      }
      final rows = await query.orderBy('id').limit(_pollBatch).get();
      Map<String, Object?>? row;
      for (final candidate in rows) {
        if (isForeignPayload(candidate['payload']! as String)) {
          _rememberForeign(queue, candidate);
          continue;
        }
        row = candidate;
        break;
      }
      if (row == null) {
        if (rows.length == _pollBatch) {
          continue; // A full batch of foreign jobs: look further.
        }
        return null;
      }
      final id = row['id']!;
      final previousReserved = row['reserved_at'];
      final claimed = await _query()
          .where('id', id)
          .where((QueryBuilder q) {
            if (previousReserved == null) {
              q.whereNull('reserved_at');
            } else {
              q.where('reserved_at', previousReserved);
            }
          })
          .update(<String, Object?>{
            'reserved_at': now,
            'attempts': (row['attempts'] as num).toInt() + 1,
          });
      if (claimed == 1) {
        final raw = row['payload'] as String;
        return QueuedJob(
          id: id,
          queue: queue,
          payload: JobPayload.decode(raw),
          attempts: (row['attempts'] as num).toInt() + 1,
          raw: raw,
        );
      }
    }
    return null;
  }

  void _rememberForeign(String queue, Map<String, Object?> row) {
    final ids = _foreign.putIfAbsent(queue, () => <Object>{});
    final id = row['id']!;
    if (!ids.add(id)) {
      return;
    }
    if (ids.length > _maxForeignIds) {
      ids.remove(ids.first);
    }
    String handler;
    try {
      final decoded = jsonDecode(row['payload']! as String);
      handler = decoded is Map<String, Object?> ? '${decoded['job']}' : '?';
    } on FormatException {
      handler = '?';
    }
    onForeignJob?.call(queue, id, handler);
  }

  @override
  Future<void> release(QueuedJob job, Duration delay) async {
    await _query().where('id', job.id).update(<String, Object?>{
      'reserved_at': null,
      'available_at': _now + delay.inSeconds,
    });
  }

  @override
  Future<void> delete(QueuedJob job) async {
    await _query().where('id', job.id).delete();
  }

  @override
  Future<int> size(String queue) => _query().where('queue', queue).count();

  /// Measured from `available_at` of unreserved ready rows (Laravel's
  /// columns), so jobs pushed by either runtime count.
  @override
  Future<Duration?> oldestWait(String queue) async {
    final now = _now;
    final oldest = await _query()
        .where('queue', queue)
        .whereNull('reserved_at')
        .where('available_at', '<=', now)
        .min('available_at');
    return oldest == null
        ? null
        : Duration(seconds: now - (oldest as num).toInt());
  }

  @override
  Future<int> clear(String queue) => _query().where('queue', queue).delete();

  static DateTime _utcNow() => Clock.now().toUtc();
}

/// Runs jobs inline at push time (dev/test). [processor] is wired by the
/// queue manager.
final class SyncQueue implements QueueDriver {
  SyncQueue();

  /// Processes a payload immediately; set by `QueueManager`.
  Future<void> Function(JobPayload payload, String queue)? processor;

  int _pushed = 0;

  @override
  String get name => 'sync';

  @override
  StateScope get scope => StateScope.isolate;

  @override
  Future<Object> push(
    JobPayload payload, {
    required String queue,
    Duration? delay,
  }) async {
    final id = ++_pushed;
    final run = processor;
    if (run == null) {
      throw StateError('SyncQueue has no processor attached.');
    }
    await run(payload, queue);
    return id;
  }

  @override
  Future<QueuedJob?> pop(String queue) async => null;

  @override
  Future<void> release(QueuedJob job, Duration delay) async {}

  @override
  Future<void> delete(QueuedJob job) async {}

  @override
  Future<int> size(String queue) async => 0;

  @override
  Future<Duration?> oldestWait(String queue) async => null;

  @override
  Future<int> clear(String queue) async => 0;
}

/// A row of `failed_jobs`.
final class FailedJob {
  const FailedJob({
    required this.id,
    required this.uuid,
    required this.connection,
    required this.queue,
    required this.payload,
    required this.exception,
    required this.failedAt,
  });

  final Object id;
  final String uuid;
  final String connection;
  final String queue;
  final String payload;
  final String exception;
  final DateTime failedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'uuid': uuid,
    'connection': connection,
    'queue': queue,
    'failed_at': failedAt.toIso8601String(),
    'exception': exception.split('\n').first,
  };
}

/// Storage for failed jobs (Laravel `FailedJobProviderInterface`).
abstract interface class FailedJobProvider {
  Future<Object> log({
    required String connection,
    required String queue,
    required String payload,
    required String exception,
  });

  Future<List<FailedJob>> all();

  Future<FailedJob?> find(Object id);

  Future<bool> forget(Object id);

  Future<int> flush();

  /// Deletes entries older than [olderThan]; returns the count.
  Future<int> prune(Duration olderThan);
}

/// In-memory failed job list (sync/memory connections, tests).
final class MemoryFailedJobProvider implements FailedJobProvider {
  final List<FailedJob> _jobs = <FailedJob>[];
  int _nextId = 0;

  @override
  Future<Object> log({
    required String connection,
    required String queue,
    required String payload,
    required String exception,
  }) async {
    final id = ++_nextId;
    _jobs.add(
      FailedJob(
        id: id,
        uuid: JobPayload.decode(payload).uuid,
        connection: connection,
        queue: queue,
        payload: payload,
        exception: exception,
        failedAt: Clock.now().toUtc(),
      ),
    );
    return id;
  }

  @override
  Future<List<FailedJob>> all() async => List<FailedJob>.unmodifiable(_jobs);

  @override
  Future<FailedJob?> find(Object id) async {
    for (final job in _jobs) {
      if (job.id == id || '${job.id}' == '$id' || job.uuid == id) {
        return job;
      }
    }
    return null;
  }

  @override
  Future<bool> forget(Object id) async {
    final before = _jobs.length;
    _jobs.removeWhere((j) => j.id == id || '${j.id}' == '$id' || j.uuid == id);
    return _jobs.length < before;
  }

  @override
  Future<int> flush() async {
    final count = _jobs.length;
    _jobs.clear();
    return count;
  }

  @override
  Future<int> prune(Duration olderThan) async {
    final cutoff = Clock.now().toUtc().subtract(olderThan);
    final before = _jobs.length;
    _jobs.removeWhere((j) => j.failedAt.isBefore(cutoff));
    return before - _jobs.length;
  }
}

/// Laravel-compatible `failed_jobs` table.
final class DatabaseFailedJobProvider implements FailedJobProvider {
  DatabaseFailedJobProvider(
    this.db, {
    this.table = 'failed_jobs',
    this.connection,
  });

  final DatabaseManager db;
  final String table;
  final String? connection;

  QueryBuilder _query() => db.table(table, connection: connection);

  @override
  Future<Object> log({
    required String connection,
    required String queue,
    required String payload,
    required String exception,
  }) async {
    final id = await _query().insertGetId(<String, Object?>{
      'uuid': JobPayload.decode(payload).uuid,
      'connection': connection,
      'queue': queue,
      'payload': payload,
      'exception': exception,
      'failed_at': Clock.now().toUtc(),
    });
    return id!;
  }

  @override
  Future<List<FailedJob>> all() async =>
      (await _query().orderBy('id', 'desc').get()).map(_fromRow).toList();

  @override
  Future<FailedJob?> find(Object id) async {
    final row = await _query().where((QueryBuilder q) {
      q.where('id', id).orWhere('uuid', '$id');
    }).first();
    return row == null ? null : _fromRow(row);
  }

  @override
  Future<bool> forget(Object id) async =>
      await _query().where((QueryBuilder q) {
        q.where('id', id).orWhere('uuid', '$id');
      }).delete() >
      0;

  @override
  Future<int> flush() => _query().delete();

  @override
  Future<int> prune(Duration olderThan) => _query()
      .where('failed_at', '<', Clock.now().toUtc().subtract(olderThan))
      .delete();

  static FailedJob _fromRow(Map<String, Object?> row) => FailedJob(
    id: row['id']!,
    uuid: row['uuid'] as String,
    connection: row['connection'] as String,
    queue: row['queue'] as String,
    payload: row['payload'] as String,
    exception: row['exception'] as String,
    failedAt: _parse(row['failed_at']) ?? Clock.now().toUtc(),
  );

  static DateTime? _parse(Object? value) => switch (value) {
    DateTime() => value.toUtc(),
    String() => DateTime.tryParse(value)?.toUtc(),
    int() => DateTime.fromMillisecondsSinceEpoch(value, isUtc: true),
    _ => null,
  };
}

/// Creates `jobs`, `job_batches` and `failed_jobs` with Laravel 11's schema
/// and migration name.
final class CreateJobsTable extends Migration {
  const CreateJobsTable();

  @override
  String get name => '0001_01_01_000002_create_jobs_table';

  @override
  Future<void> up(SchemaBuilder schema) async {
    await schema.create('jobs', (table) {
      table.id();
      table.string('queue').index();
      table.longText('payload');
      table.tinyInteger('attempts').unsigned();
      table.unsignedInteger('reserved_at').nullable();
      table.unsignedInteger('available_at');
      table.unsignedInteger('created_at');
    });
    await schema.create('job_batches', (table) {
      table.string('id').primary();
      table.string('name');
      table.integer('total_jobs');
      table.integer('pending_jobs');
      table.integer('failed_jobs');
      table.longText('failed_job_ids');
      table.mediumText('options').nullable();
      table.integer('cancelled_at').nullable();
      table.integer('created_at');
      table.integer('finished_at').nullable();
    });
    await schema.create('failed_jobs', (table) {
      table.id();
      table.string('uuid').unique();
      table.text('connection');
      table.text('queue');
      table.longText('payload');
      table.longText('exception');
      table.timestamp('failed_at').useCurrent();
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    await schema.dropIfExists('failed_jobs');
    await schema.dropIfExists('job_batches');
    await schema.dropIfExists('jobs');
  }
}
