import 'dart:async';
import 'dart:convert';

import 'package:daravel/daravel.dart';

import 'horizon_store.dart';
import 'process_store.dart';

/// The tables of the `database` store ([DatabaseHorizonStore]). Add it to
/// the application's migrations, as `CreateSessionsTable` of
/// `daravel_session`. Laravel Horizon keeps everything in Redis and
/// creates no table, so a database shared with Laravel has no `horizon_*`
/// table of its own to collide with.
final class CreateHorizonTables extends Migration {
  /// The migration creating `horizon_jobs`, `horizon_job_counts`,
  /// `horizon_job_tags`,
  /// `horizon_monitored_tags` and `horizon_snapshots`.
  const CreateHorizonTables();

  @override
  String get name => '0001_01_01_000010_create_horizon_tables';

  @override
  Future<void> up(SchemaBuilder schema) async {
    await schema.create('horizon_jobs', (table) {
      table.id();
      table.string('uuid').unique();
      table.string('name');
      table.string('queue');
      table.string('status', length: 16);
      table.bigInteger('at');
      table.integer('duration_ms').nullable();
      table.text('record');
      // The lists (`recent`) and the trim, by status, newest first.
      table.index(['status', 'at']);
      // The rates of a queue over the last minute.
      table.index(['queue', 'at']);
    });
    // What the counts read (rates, summary, snapshots): every job that
    // finished, once per uuid and status, never replaced by a later record.
    await schema.create('horizon_job_counts', (table) {
      table.id();
      table.string('uuid');
      table.string('status', length: 16);
      table.string('name');
      table.string('queue');
      table.bigInteger('at');
      table.integer('duration_ms').nullable();
      table.unique(['uuid', 'status']);
      table.index(['status', 'at']);
      table.index(['queue', 'at']);
    });
    await schema.create('horizon_job_tags', (table) {
      table.id();
      table.string('tag');
      table.string('job_uuid');
      table.bigInteger('at');
      table.text('record');
      table.unique(['tag', 'job_uuid']);
      table.index(['tag', 'at']);
    });
    await schema.create('horizon_monitored_tags', (table) {
      table.string('tag').primary();
    });
    await schema.create('horizon_snapshots', (table) {
      table.id();
      table.string('kind', length: 8);
      table.string('key');
      table.bigInteger('taken_at');
      table.integer('count');
      table.doublePrecision('avg_ms').nullable();
      table.index(['kind', 'key', 'taken_at']);
    });
  }

  @override
  Future<void> down(SchemaBuilder schema) async {
    for (final table in const [
      'horizon_snapshots',
      'horizon_monitored_tags',
      'horizon_job_tags',
      'horizon_job_counts',
      'horizon_jobs',
    ]) {
      await schema.dropIfExists(table);
    }
  }
}

/// Why a record did not reach the store (`horizon_store_dropped_total`).
enum HorizonStoreDrop {
  /// The buffer was full: the oldest record went.
  overflow,

  /// Writing failed (the database refused or was unreachable).
  error,
}

/// The `database` store (`HORIZON_STORE=database`): the tables of
/// [CreateHorizonTables] on [connection], shared by every process using
/// that database, so a dashboard served elsewhere reads what the workers
/// recorded.
///
/// Records are buffered per isolate and written in batches: every
/// [flushEvery] (wall clock) or once [batchSize] are waiting, in one
/// statement, outside any transaction of the job that recorded them (a
/// job's failure must be recorded although its own transaction rolled
/// back). [close] writes what is left; `withHorizon()` calls it at shutdown,
/// before the database connections close. A record dropped (the buffer full
/// at [maxBuffered], or the database failing) is counted in
/// `horizon_store_dropped_total{store="database",reason}`, and logged at most
/// once a minute.
///
/// The batches run in the root zone, so they never join a transaction of
/// the code that recorded (nor a test's `rollbackAfter`). On a SQLite file,
/// whose one connection a transaction holds, a flush awaited inside an open
/// transaction therefore waits for it, then fails (counted): workers record
/// after a job's transaction has ended, and the timer flushes later.
///
/// Each write trims the rows past their retention, at most [trimBatch] per
/// table, so the tables stay bounded without a scheduler; `horizon:prune`
/// trims all. Retention and snapshot times are domain time ([Clock.now]).
final class DatabaseHorizonStore implements HorizonStore {
  /// The store on [connection] (the default one when null) of [database].
  DatabaseHorizonStore(
    this.database, {
    this.connection,
    this.retention = const Duration(minutes: 60),
    this.failedRetention = const Duration(days: 7),
    this.monitoredRetention = const Duration(days: 7),
    this.flushEvery = const Duration(milliseconds: 250),
    this.batchSize = 100,
    this.maxBuffered = 10000,
    this.trimBatch = 100,
    this.maxSnapshots = HorizonService.maxSnapshots,
    this.appMetrics,
    this.logger,
  });

  /// Where the tables are.
  final DatabaseManager database;

  /// The connection of the tables; the default one when null.
  final String? connection;

  /// How long completed and silenced jobs are kept.
  final Duration retention;

  /// How long failed jobs are kept.
  final Duration failedRetention;

  /// How long the jobs of monitored tags are kept.
  final Duration monitoredRetention;

  /// The longest a record waits in the buffer (wall clock).
  final Duration flushEvery;

  /// The most records written by one statement; a full batch is written at
  /// once.
  final int batchSize;

  /// The most records waiting; past it the oldest are dropped.
  final int maxBuffered;

  /// The most rows one write trims per table.
  final int trimBatch;

  /// The snapshots kept per job name and per queue.
  final int maxSnapshots;

  /// Where dropped records are counted.
  final AppMetrics? appMetrics;

  /// Where dropped records are logged (at most once a minute).
  final Logger? logger;

  final List<RecordedJob> _buffer = [];
  Timer? _timer;
  Future<void>? _flushing;
  DateTime? _lastDropLog;
  bool _closed = false;

  int get _now => Clock.now().millisecondsSinceEpoch;

  QueryBuilder _table(String name) =>
      database.table(name, connection: connection);

  // -- writes ---------------------------------------------------------------

  @override
  Future<void> record(RecordedJob job) async {
    if (_closed) {
      _dropped(HorizonStoreDrop.overflow, 1);
      return;
    }
    _buffer.add(job);
    if (_buffer.length > maxBuffered) {
      final excess = _buffer.length - maxBuffered;
      _buffer.removeRange(0, excess);
      _dropped(HorizonStoreDrop.overflow, excess);
    }
    if (_buffer.length >= batchSize) {
      _timer?.cancel();
      _timer = null;
      unawaited(flush());
    } else {
      // A wall-clock timer, in the root zone: neither a frozen test clock
      // nor the job's own zone (its transaction) holds the write.
      _timer ??= Zone.root.createTimer(flushEvery, () {
        _timer = null;
        unawaited(flush());
      });
    }
  }

  /// Writes what is buffered now; completes once it is written (or
  /// dropped). Never throws.
  Future<void> flush() {
    final running = _flushing;
    if (running != null) {
      return running.then((_) => _buffer.isEmpty ? null : flush());
    }
    if (_buffer.isEmpty) {
      return Future<void>.value();
    }
    final done = _flushing = Zone.root.run(_writeAll).whenComplete(() {
      _flushing = null;
    });
    return done;
  }

  Future<void> _writeAll() async {
    while (_buffer.isNotEmpty) {
      final batch = _buffer.take(batchSize).toList();
      _buffer.removeRange(0, batch.length);
      try {
        await _write(batch);
      } on Object catch (error) {
        _dropped(HorizonStoreDrop.error, batch.length, error);
      }
    }
  }

  /// Writes [batch]: one row per job, the newest record of each uuid
  /// winning over the batch and over the rows already there.
  Future<void> _write(List<RecordedJob> batch) async {
    final newest = <String, RecordedJob>{};
    for (final job in batch) {
      final seen = newest[job.uuid];
      if (seen == null || seen.at <= job.at) {
        newest[job.uuid] = job;
      }
    }
    final monitored = {
      for (final row in await _table('horizon_monitored_tags').get())
        '${row['tag']}',
    };
    final counted = <String, RecordedJob>{
      for (final job in batch) '${job.uuid}|${job.status}': job,
    };
    await database.transaction(() async {
      await _table('horizon_job_counts').insertOrIgnore([
        for (final job in counted.values)
          {
            'uuid': job.uuid,
            'status': job.status,
            'name': job.name,
            'queue': job.queue,
            'at': job.at,
            'duration_ms': job.durationMs,
          },
      ]);
      final existing = {
        for (final row in await _table(
          'horizon_jobs',
        ).whereIn('uuid', newest.keys.toList()).select(['uuid', 'at']).get())
          '${row['uuid']}': (row['at']! as num).toInt(),
      };
      // An older record arriving late never replaces a newer one.
      newest.removeWhere((uuid, job) => (existing[uuid] ?? -1) > job.at);
      if (newest.isEmpty) {
        return;
      }
      final replaced = [
        for (final uuid in newest.keys)
          if (existing.containsKey(uuid)) uuid,
      ];
      if (replaced.isNotEmpty) {
        await _table('horizon_jobs').whereIn('uuid', replaced).delete();
      }
      await _table('horizon_jobs').insert([
        for (final job in newest.values)
          {
            'uuid': job.uuid,
            'name': job.name,
            'queue': job.queue,
            'status': job.status,
            'at': job.at,
            'duration_ms': job.durationMs,
            'record': jsonEncode(job.toJson()),
          },
      ]);
      final tagged = [
        for (final job in newest.values)
          for (final tag in job.tags)
            if (monitored.contains(tag))
              {
                'tag': tag,
                'job_uuid': job.uuid,
                'at': job.at,
                'record': jsonEncode(job.toJson()),
              },
      ];
      if (tagged.isNotEmpty) {
        final uuids = {for (final row in tagged) row['job_uuid']!}.toList();
        await _table('horizon_job_tags').whereIn('job_uuid', uuids).delete();
        await _table('horizon_job_tags').insert(tagged);
      }
    }, connection: connection);
    await _trim();
  }

  /// Deletes up to [limit] rows of each table past their retention; the
  /// number deleted. Two statements per table (the ids, then a delete by
  /// id), since `DELETE … LIMIT` is not portable (PostgreSQL has none, and
  /// MySQL refuses `LIMIT` inside an `IN` subquery).
  Future<int> _trim({int? limit}) async {
    final now = _now;
    final take = limit ?? trimBatch;
    var deleted = 0;
    Future<void> trim(
      String table,
      void Function(QueryBuilder query) old,
    ) async {
      final query = _table(table)..select(['id']);
      old(query);
      final ids = [
        for (final row in await query.orderBy('at').limit(take).get())
          row['id'],
      ];
      if (ids.isNotEmpty) {
        deleted += await _table(table).whereIn('id', ids).delete();
      }
    }

    final finished = now - retention.inMilliseconds;
    final failed = now - failedRetention.inMilliseconds;
    await trim(
      'horizon_jobs',
      (q) => q
          .where((QueryBuilder w) {
            w
              ..where('status', '!=', 'failed')
              ..where('at', '<', finished);
          })
          .orWhere((QueryBuilder w) {
            w
              ..where('status', 'failed')
              ..where('at', '<', failed);
          }),
    );
    await trim(
      'horizon_job_counts',
      (q) => q
          .where((QueryBuilder w) {
            w
              ..where('status', '!=', 'failed')
              ..where('at', '<', finished);
          })
          .orWhere((QueryBuilder w) {
            w
              ..where('status', 'failed')
              ..where('at', '<', failed);
          }),
    );
    await trim(
      'horizon_job_tags',
      (q) => q.where('at', '<', now - monitoredRetention.inMilliseconds),
    );
    return deleted;
  }

  /// Deletes every row past its retention (`horizon:prune`); the number
  /// deleted.
  Future<int> prune() async {
    await flush();
    var total = 0;
    while (true) {
      final deleted = await Zone.root.run(() => _trim(limit: 1000));
      total += deleted;
      if (deleted == 0) {
        return total;
      }
    }
  }

  /// Writes what is buffered and stops buffering: later records are
  /// dropped (counted). Called at shutdown, before the connections close.
  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    await flush();
    _closed = true;
  }

  void _dropped(HorizonStoreDrop reason, int count, [Object? error]) {
    appMetrics?.registry
        .counter(
          'horizon_store_dropped_total',
          'Records Horizon could not keep in its store.',
        )
        .inc({'store': 'database', 'reason': reason.name}, count.toDouble());
    final now = DateTime.now();
    final last = _lastDropLog;
    if (last == null || now.difference(last) >= const Duration(minutes: 1)) {
      _lastDropLog = now;
      logger?.warning(
        'Horizon dropped $count record(s) of its database store '
        '(${reason.name})${error == null ? '' : ': $error'}.',
      );
    }
  }

  // -- reads ----------------------------------------------------------------

  static RecordedJob _job(Map<String, Object?> row) => RecordedJob.fromJson(
    jsonDecode('${row['record']}') as Map<String, Object?>,
  );

  @override
  Future<List<RecordedJob>> recent(
    String status, {
    int limit = 50,
    int offset = 0,
  }) async => [
    for (final row
        in await _table('horizon_jobs')
            .where('status', status)
            .where('at', '>=', _now - _keep(status).inMilliseconds)
            .orderBy('at', 'desc')
            .orderBy('id', 'desc')
            .offset(offset)
            .limit(limit)
            .get())
      _job(row),
  ];

  Duration _keep(String status) =>
      status == 'failed' ? failedRetention : retention;

  @override
  Future<RecordedJob?> job(String uuid) async {
    final row = await _table('horizon_jobs').where('uuid', uuid).first();
    return row == null ? null : _job(row);
  }

  @override
  Future<Map<String, Object?>> rates(String queue) async {
    final rows = await _table('horizon_job_counts')
        .where('queue', queue)
        .where('at', '>=', _now - 60000)
        .select(['duration_ms'])
        .get();
    final timed = [
      for (final row in rows)
        if (row['duration_ms'] case final num ms) ms,
    ];
    return {
      'per_second': rows.length / 60,
      'avg_ms': timed.isEmpty
          ? null
          : timed.reduce((a, b) => a + b) / timed.length,
    };
  }

  @override
  Future<Map<String, Object?>> summary() async {
    final now = _now;
    Future<int> within(Duration window, {String? status}) {
      final query = _table('horizon_job_counts')
          .where('at', '>=', now - window.inMilliseconds);
      if (status != null) {
        query.where('status', status);
      }
      return query.count();
    }

    return {
      'jobs_per_minute': await within(const Duration(minutes: 1)),
      'jobs_past_hour': await within(const Duration(hours: 1)),
      'failed_past_week': await within(
        const Duration(days: 7),
        status: 'failed',
      ),
    };
  }

  @override
  Future<void> monitor(String tag) => Zone.root.run(() async {
    if (await _table('horizon_monitored_tags').where('tag', tag).exists()) {
      return;
    }
    await _table('horizon_monitored_tags').insert({'tag': tag});
  });

  @override
  Future<void> unmonitor(String tag) => Zone.root.run(() async {
    await _table('horizon_monitored_tags').where('tag', tag).delete();
    await _table('horizon_job_tags').where('tag', tag).delete();
  });

  @override
  Future<List<Map<String, Object?>>> monitored() async => [
    for (final row in await _table(
      'horizon_monitored_tags',
    ).orderBy('tag').get())
      {
        'tag': row['tag'],
        'count': await _table('horizon_job_tags')
            .where('tag', row['tag'])
            .count(),
      },
  ];

  @override
  Future<List<RecordedJob>> tagged(String tag, {int limit = 50}) async => [
    for (final row
        in await _table('horizon_job_tags')
            .where('tag', tag)
            .orderBy('at', 'desc')
            .orderBy('id', 'desc')
            .limit(limit)
            .get())
      _job(row),
  ];

  @override
  Future<void> snapshot() => Zone.root.run(() async {
    final now = _now;
    final last = await _table('horizon_snapshots').max('taken_at');
    final since = last == null
        ? now - retention.inMilliseconds
        : (last as num).toInt();
    final rows = await _table('horizon_job_counts')
        .where('at', '>', since)
        .where('at', '<=', now)
        .select(['name', 'queue', 'duration_ms'])
        .get();
    Future<void> add(String kind, String column) async {
      final groups = <String, List<num?>>{};
      for (final row in rows) {
        groups
            .putIfAbsent('${row[column]}', () => [])
            .add(row['duration_ms'] as num?);
      }
      // A key with no job since keeps its series going, as the process
      // store's does.
      final known = {
        for (final row in await _table(
          'horizon_snapshots',
        ).where('kind', kind).select(['key']).distinct().get())
          '${row['key']}',
      };
      final keys = {...known, ...groups.keys};
      if (keys.isEmpty) {
        return;
      }
      await _table('horizon_snapshots').insert([
        for (final key in keys)
          () {
            final durations = groups[key] ?? const <num?>[];
            final timed = [for (final d in durations) ?d];
            return {
              'kind': kind,
              'key': key,
              'taken_at': now,
              'count': durations.length,
              'avg_ms': timed.isEmpty
                  ? null
                  : timed.reduce((a, b) => a + b) / timed.length,
            };
          }(),
      ]);
      for (final key in keys) {
        final old = [
          for (final row
              in await _table('horizon_snapshots')
                  .where('kind', kind)
                  .where('key', key)
                  .orderBy('taken_at', 'desc')
                  .offset(maxSnapshots)
                  .limit(1000)
                  .select(['id'])
                  .get())
            row['id'],
        ];
        if (old.isNotEmpty) {
          await _table('horizon_snapshots').whereIn('id', old).delete();
        }
      }
    }

    await add('job', 'name');
    await add('queue', 'queue');
  });

  @override
  Future<Map<String, Object?>> metrics() async {
    final out = {
      'jobs': <String, List<Map<String, Object?>>>{},
      'queues': <String, List<Map<String, Object?>>>{},
    };
    for (final row in await _table(
      'horizon_snapshots',
    ).orderBy('taken_at').orderBy('id').get()) {
      final into = row['kind'] == 'job' ? out['jobs']! : out['queues']!;
      into.putIfAbsent('${row['key']}', () => []).add({
        'at': (row['taken_at']! as num).toInt(),
        'count': (row['count']! as num).toInt(),
        'avg_ms': (row['avg_ms'] as num?)?.toDouble(),
      });
    }
    return out;
  }
}
