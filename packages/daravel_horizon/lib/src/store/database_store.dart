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
      // Covers `rates` (COUNT and AVG of a queue's last minute) from the
      // index alone: without duration_ms, MySQL scanned the whole table.
      table.index(['queue', 'at', 'duration_ms']);
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

  /// Recorded after [DatabaseHorizonStore.close] (the application shutting
  /// down): nothing writes it any more.
  closed,
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
final class DatabaseHorizonStore implements BufferedHorizonStore {
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
    this.trimEvery = const Duration(seconds: 1),
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

  /// The least time between two trims of this store (wall clock).
  final Duration trimEvery;

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
      _dropped(HorizonStoreDrop.closed, 1);
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
        if (batch.length == 1) {
          _dropped(HorizonStoreDrop.error, 1, error);
        } else {
          await _writeOneByOne(batch);
        }
      }
    }
  }

  /// After [batch] failed as a whole (its transaction rolled back): each
  /// record alone, so one the database refuses costs only itself. After
  /// [_failuresInARow] failures in a row the store itself is failing
  /// (unreachable, out of space), not a record, and the rest is dropped
  /// rather than tried one by one.
  Future<void> _writeOneByOne(List<RecordedJob> batch) async {
    var inARow = 0;
    var lost = 0;
    Object? last;
    for (var i = 0; i < batch.length; i++) {
      if (inARow >= _failuresInARow) {
        lost += batch.length - i;
        break;
      }
      try {
        await _write([batch[i]]);
        inARow = 0;
      } on Object catch (error) {
        inARow++;
        lost++;
        last = error;
      }
    }
    if (lost > 0) {
      _dropped(HorizonStoreDrop.error, lost, last);
    }
  }

  static const int _failuresInARow = 3;

  /// The widest value the `string` columns of these tables hold, in
  /// characters (`varchar(255)`).
  static const int columnWidth = 255;

  /// [value] fitted to [columnWidth] characters (code points): a longer
  /// one is cut, its last character replaced by `…` to show it. The
  /// record (`record`, a text column) keeps the whole value; the columns
  /// are what lists, counts and tags are looked up by.
  static String fit(String value) {
    if (value.length <= columnWidth) {
      return value; // Never more code points than UTF-16 units.
    }
    final runes = value.runes;
    if (runes.length <= columnWidth) {
      return value;
    }
    return '${String.fromCharCodes(runes.take(columnWidth - 1))}…';
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
            'uuid': fit(job.uuid),
            'status': job.status,
            'name': fit(job.name),
            'queue': fit(job.queue),
            'at': job.at,
            'duration_ms': job.durationMs,
          },
      ]);
      // Two workers may write the same job at once (a job failed on one and
      // retried at once on another): neither sees the other's row before
      // it commits. So rows are inserted unless there, then each is made
      // the newest record with a conditional update, atomic per row: no
      // unique-key violation drops the batch, and no status steps back.
      final rows = [
        for (final job in newest.values)
          {
            'uuid': fit(job.uuid),
            'name': fit(job.name),
            'queue': fit(job.queue),
            'status': job.status,
            'at': job.at,
            'duration_ms': job.durationMs,
            'record': jsonEncode(job.toJson()),
          },
      ];
      await _upsertNewest(
        'horizon_jobs',
        rows,
        where: (row, query) => query.where('uuid', row['uuid']),
      );
      final tagged = [
        for (final job in newest.values)
          for (final tag in job.tags.map(fit))
            if (monitored.contains(tag))
              {
                'tag': tag,
                'job_uuid': fit(job.uuid),
                'at': job.at,
                'record': jsonEncode(job.toJson()),
              },
      ];
      if (tagged.isNotEmpty) {
        await _upsertNewest(
          'horizon_job_tags',
          tagged,
          where: (row, query) =>
              query.where('tag', row['tag']).where('job_uuid', row['job_uuid']),
        );
      }
    }, connection: connection);
    await _maybeTrim();
  }

  /// Inserts [rows] into [table] unless a row with their key ([where]) is
  /// there, then updates each such row whose record is older than or as
  /// old as this one (`at`): the newest record wins, whichever writer
  /// commits first. The updates are skipped when every row was new.
  Future<void> _upsertNewest(
    String table,
    List<Map<String, Object?>> rows, {
    required QueryBuilder Function(Map<String, Object?> row, QueryBuilder q)
    where,
  }) async {
    final inserted = await _table(table).insertOrIgnore(rows);
    if (inserted == rows.length) {
      return;
    }
    for (final row in rows) {
      await where(row, _table(table)).where('at', '<=', row['at']).update({
        for (final e in row.entries) e.key: e.value,
      });
    }
  }

  DateTime? _trimmedAt;

  /// Trims at most once per [trimEvery] (wall clock) and store: a select
  /// and a delete per table on every flush of every worker would cost more
  /// than the rows they remove. A trim that fails is logged; the next one
  /// takes those rows.
  Future<void> _maybeTrim() async {
    final now = DateTime.now();
    final last = _trimmedAt;
    if (last != null && now.difference(last) < trimEvery) {
      return;
    }
    _trimmedAt = now;
    try {
      await _trim();
    } on Object catch (e) {
      logger?.warning('Horizon could not trim its database store: $e');
    }
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
  @override
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
    final row = await _table('horizon_jobs').where('uuid', fit(uuid)).first();
    return row == null ? null : _job(row);
  }

  @override
  Future<Map<String, Object?>> rates(String queue) async {
    // Counted by the database: the master asks for each queue on every
    // evaluation, and a busy minute holds many thousands of rows.
    // One statement; AVG skips NULL: the average of the jobs that have a
    // run time.
    final row = await _table('horizon_job_counts')
        .where('queue', fit(queue))
        .where('at', '>=', _now - 60000)
        .selectRaw('COUNT(*) AS jobs, AVG(duration_ms) AS avg_ms')
        .first();
    final count = _number(row?['jobs'])?.toInt() ?? 0;
    return {
      'per_second': count / 60,
      'avg_ms': _number(row?['avg_ms'])?.toDouble(),
    };
  }

  /// An aggregate's value: PostgreSQL returns `AVG` (and `SUM`, `COUNT`
  /// on some drivers) as `numeric`, which arrives as a string.
  static num? _number(Object? value) => switch (value) {
    null => null,
    final num n => n,
    final String s => num.parse(s),
    _ => throw StateError('Not a number from the database: $value'),
  };

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
    // Two dashboards may monitor the same tag at once.
    await _table('horizon_monitored_tags').insertOrIgnore({'tag': fit(tag)});
  });

  @override
  Future<void> unmonitor(String tag) => Zone.root.run(() async {
    await _table('horizon_monitored_tags').where('tag', fit(tag)).delete();
    await _table('horizon_job_tags').where('tag', fit(tag)).delete();
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
            .where('tag', fit(tag))
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
        : _number(last)!.toInt();
    Future<void> add(String kind, String column) async {
      // Grouped by the database, not read row by row.
      final groups = <String, ({int count, double? avg})>{
        for (final row
            in await _table('horizon_job_counts')
                .where('at', '>', since)
                .where('at', '<=', now)
                .select([column])
                .selectRaw('COUNT(*) AS jobs, AVG(duration_ms) AS avg_ms')
                .groupBy([column])
                .get())
          '${row[column]}': (
            count: _number(row['jobs'])!.toInt(),
            avg: _number(row['avg_ms'])?.toDouble(),
          ),
      };
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
          {
            'kind': kind,
            'key': key,
            'taken_at': now,
            'count': groups[key]?.count ?? 0,
            'avg_ms': groups[key]?.avg,
          },
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
