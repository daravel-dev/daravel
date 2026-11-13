import 'dart:async';
import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';

import 'client.dart';

/// The `redis` Horizon store (`HORIZON_STORE=redis`, `withRedis()`): what
/// Horizon shows, kept in Redis so a dashboard served by another process
/// than `dartisan horizon` reads what its workers recorded.
///
/// Every key starts with `REDIS_PREFIX` and the hash tag
/// `{daravel:horizon}`, so a Redis Cluster keeps them in one slot (one
/// node holds Horizon's data, a few MB) and each script runs there:
///
/// - `job:<uuid>`: a hash with the job's newest record, its time and
///   status, and the statuses already counted;
/// - `jobs:<status>` and `recent`: sorted sets by time, trimmed by
///   retention **and** by [maxPerStatus]; a job's hash is kept while a
///   list (or a monitored tag) still refers to it;
/// - `counts:s:<second>`, `counts:m:<minute>`, `counts:h:<hour>`: the
///   counts behind `rates` and `summary` (exact over the last minute; the
///   past hour by minute, the past week by hour), which the list limits
///   never cut;
/// - `snap:pending`: what happened since the last [snapshot], and
///   `snap:<kind>:<key>` the [maxSnapshots] latest per job name and queue;
/// - `monitored` and `tag:<tag>`: the monitored tags and their jobs.
///
/// Every key but `monitored` expires on its own (its retention, renewed by
/// each write), so Redis cleans up after a Horizon that stopped. The
/// scripts take every key through `KEYS` and the time through `ARGV`, so
/// the test clock applies. Records are buffered and written in batches
/// (every [flushEvery] or [batchSize] records) outside the job's zone; a
/// record that cannot be written is counted in
/// `horizon_store_dropped_total{store="redis",reason}`.
///
/// A record counts once per job and status. That is remembered in the
/// job's hash: a duplicate arriving after the hash was trimmed (past
/// [maxPerStatus] newer jobs) counts again.
final class RedisHorizonStore implements BufferedHorizonStore {
  /// The store on [client], its keys after [prefix].
  RedisHorizonStore(
    this.client, {
    this.prefix = '',
    this.retention = const Duration(minutes: 60),
    this.failedRetention = const Duration(days: 7),
    this.monitoredRetention = const Duration(days: 7),
    this.maxPerStatus = 10000,
    this.flushEvery = const Duration(milliseconds: 250),
    this.batchSize = 100,
    this.maxBuffered = 10000,
    this.maxSnapshots = HorizonService.maxSnapshots,
    this.appMetrics,
    this.logger,
  });

  /// The connection.
  final RedisClient client;

  /// `REDIS_PREFIX`, before the hash tag.
  final String prefix;

  /// How long completed, pending and silenced jobs are listed.
  final Duration retention;

  /// How long failed jobs are listed.
  final Duration failedRetention;

  /// How long the jobs of monitored tags are kept.
  final Duration monitoredRetention;

  /// The most jobs each list keeps (`HORIZON_STORE_MAX_PER_STATUS`).
  final int maxPerStatus;

  /// The longest a record waits in the buffer (wall clock).
  final Duration flushEvery;

  /// The most records one script writes.
  final int batchSize;

  /// The most records waiting; past it the oldest are dropped.
  final int maxBuffered;

  /// The snapshots kept per job name and per queue.
  final int maxSnapshots;

  /// Where dropped records are counted.
  final AppMetrics? appMetrics;

  /// Where dropped records are logged (at most once a minute).
  final Logger? logger;

  /// The statuses Horizon records; each has its list.
  static const List<String> statuses = [
    'pending',
    'completed',
    'silenced',
    'failed',
  ];

  final List<RecordedJob> _buffer = [];
  Timer? _timer;
  Future<void>? _flushing;
  DateTime? _lastDropLog;
  bool _closed = false;

  int get _now => Clock.now().millisecondsSinceEpoch;

  String _key(String name) => '$prefix{daravel:horizon}:$name';

  Duration _keep(String status) =>
      status == 'failed' ? failedRetention : retention;

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
      // nor the job's own zone holds the write.
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

  /// Writes [batch] in one script, then forgets the hashes of the jobs
  /// the lists dropped and nothing refers to any more.
  Future<void> _write(List<RecordedJob> batch) async {
    final now = _now;
    final keys = <String>[
      _key('monitored'),
      _key('recent'),
      _key('snap:pending'),
    ];
    final lists = <String, int>{};
    for (final status in {...statuses, for (final job in batch) job.status}) {
      keys.add(_key('jobs:$status'));
      lists[status] = keys.length;
    }
    int add(String key) {
      keys.add(key);
      return keys.length;
    }

    final records = [
      for (final job in batch)
        {
          'uuid': job.uuid,
          'status': job.status,
          'queue': job.queue,
          'name': job.name,
          'at': job.at,
          'dur': job.durationMs,
          'tags': job.tags,
          // As JSON from here: Lua's cjson writes an empty list as {}.
          'tagsJson': jsonEncode(job.tags),
          'record': jsonEncode(job.toJson()),
          'k': {
            'job': add(_key('job:${job.uuid}')),
            's': add(_key('counts:s:${job.at ~/ 1000}')),
            'm': add(_key('counts:m:${job.at ~/ 60000}')),
            'h': add(_key('counts:h:${job.at ~/ 3600000}')),
            'tags': [for (final tag in job.tags) add(_key('tag:$tag'))],
          },
        },
    ];
    final config = jsonEncode({
      'lists': lists,
      'max': maxPerStatus,
      'ttl': {
        for (final status in lists.keys) status: _keep(status).inMilliseconds,
        'recent': retention.inMilliseconds,
        'monitored': monitoredRetention.inMilliseconds,
      },
    });
    final dropped = await client.eval(
      _recordScript,
      keys: keys,
      args: [now, config, jsonEncode(records)],
    );
    final gone = [
      for (final id in (dropped as List<Object?>?) ?? const []) '$id',
    ];
    if (gone.isNotEmpty) {
      // The batch is written: a failure here only leaves the hashes of
      // jobs no list shows until they expire, so it is logged, not
      // counted as dropped records.
      try {
        await _forget(gone);
      } on Object catch (error) {
        logger?.warning(
          'Horizon could not delete ${gone.length} trimmed job(s) from its '
          'redis store; they expire with their retention: $error',
        );
      }
    }
  }

  /// Deletes the hashes of [uuids] that no list or monitored tag refers
  /// to, in one script, so a job another worker listed again in between
  /// keeps its hash. Should it fail, the hashes still expire.
  Future<void> _forget(List<String> uuids) async {
    // The tags of each job, to check the monitored lists too.
    final tags = await Future.wait([
      for (final uuid in uuids)
        client.command(['HGET', _key('job:$uuid'), 'tags']),
    ]);
    final keys = <String>[
      _key('recent'),
      for (final status in statuses) _key('jobs:$status'),
    ];
    final lists = keys.length;
    final items = <Map<String, Object?>>[];
    for (var i = 0; i < uuids.length; i++) {
      keys.add(_key('job:${uuids[i]}'));
      final job = keys.length;
      final tagKeys = <int>[];
      final names = tags[i] == null
          ? const <Object?>[]
          : jsonDecode('${tags[i]}') as List<Object?>;
      for (final tag in names) {
        keys.add(_key('tag:$tag'));
        tagKeys.add(keys.length);
      }
      items.add({'uuid': uuids[i], 'job': job, 'tags': tagKeys});
    }
    await client.eval(
      _forgetScript,
      keys: keys,
      args: [
        jsonEncode({'lists': lists, 'items': items}),
      ],
    );
  }

  /// Writes what is buffered and stops taking records.
  @override
  Future<void> close() async {
    _timer?.cancel();
    _timer = null;
    await flush();
    _closed = true;
  }

  /// [body] in the root zone, outside the caller's transaction, with its
  /// result or error handed back in the caller's zone. A future failing in
  /// the root zone never reaches a listener in a request's error zone: its
  /// error would be uncaught there, and the request would wait for ever.
  static Future<T> _outside<T>(Future<T> Function() body) =>
      Zone.root.run(() => SharedResult(body)).value;

  void _dropped(HorizonStoreDrop reason, int count, [Object? error]) {
    appMetrics?.registry
        .counter(
          'horizon_store_dropped_total',
          'Records Horizon could not keep in its store.',
        )
        .inc({'store': 'redis', 'reason': reason.name}, count.toDouble());
    final now = DateTime.now();
    final last = _lastDropLog;
    if (last == null || now.difference(last) >= const Duration(minutes: 1)) {
      _lastDropLog = now;
      logger?.warning(
        'Horizon dropped $count record(s) of its redis store '
        '(${reason.name})${error == null ? '' : ': $error'}.',
      );
    }
  }

  // -- reads ----------------------------------------------------------------

  /// How many HGETs [_jobs] sends at once: a connection holds 1 024
  /// commands waiting for replies, shared with every other caller.
  static const int _readBatch = 256;

  Future<List<RecordedJob>> _jobs(List<Object?> uuids) async {
    final records = <Object?>[];
    for (var i = 0; i < uuids.length; i += _readBatch) {
      records.addAll(
        await Future.wait([
          for (final uuid in uuids.skip(i).take(_readBatch))
            client.command(['HGET', _key('job:$uuid'), 'record']),
        ]),
      );
    }
    return [
      for (final record in records)
        if (record != null)
          RecordedJob.fromJson(jsonDecode('$record') as Map<String, Object?>),
    ];
  }

  @override
  Future<List<RecordedJob>> recent(
    String status, {
    int limit = 50,
    int offset = 0,
  }) async {
    final uuids = await client.command([
      'ZRANGE',
      _key('jobs:$status'),
      '+inf',
      '${_now - _keep(status).inMilliseconds}',
      'BYSCORE',
      'REV',
      'LIMIT',
      '$offset',
      '$limit',
    ]);
    return _jobs(uuids! as List<Object?>);
  }

  @override
  Future<RecordedJob?> job(String uuid) async =>
      (await _jobs([uuid])).firstOrNull;

  /// The sums of [fields] over [bucketKeys], read in one script.
  Future<List<int>> _sum(List<String> bucketKeys, List<String> fields) async {
    final sums = await client.eval(_sumScript, keys: bucketKeys, args: fields);
    return [
      for (final value in sums! as List<Object?>) (value! as num).toInt(),
    ];
  }

  @override
  Future<Map<String, Object?>> rates(String queue) async {
    final now = _now;
    final [jobs, ms, timed] = await _sum(
      [
        for (var s = (now - 60000) ~/ 1000; s <= now ~/ 1000; s++)
          _key('counts:s:$s'),
      ],
      ['q|$queue', 'ms|$queue', 'msn|$queue'],
    );
    return {'per_second': jobs / 60, 'avg_ms': timed == 0 ? null : ms / timed};
  }

  @override
  Future<Map<String, Object?>> summary() async {
    final now = _now;
    final [minute] = await _sum(
      [
        for (var s = (now - 60000) ~/ 1000; s <= now ~/ 1000; s++)
          _key('counts:s:$s'),
      ],
      ['all'],
    );
    final [hour] = await _sum(
      [
        for (var m = (now - 3600000) ~/ 60000; m <= now ~/ 60000; m++)
          _key('counts:m:$m'),
      ],
      ['all'],
    );
    final [failed] = await _sum(
      [
        for (var h = (now - 7 * 86400000) ~/ 3600000; h <= now ~/ 3600000; h++)
          _key('counts:h:$h'),
      ],
      ['failed'],
    );
    return {
      'jobs_per_minute': minute,
      'jobs_past_hour': hour,
      'failed_past_week': failed,
    };
  }

  @override
  Future<void> monitor(String tag) => _outside(() async {
    await client.command(['SADD', _key('monitored'), tag]);
  });

  @override
  Future<void> unmonitor(String tag) => _outside(() async {
    await client.command(['SREM', _key('monitored'), tag]);
    await client.command(['DEL', _key('tag:$tag')]);
  });

  @override
  Future<List<Map<String, Object?>>> monitored() async {
    final tags = [
      for (final tag
          in (await client.command(['SMEMBERS', _key('monitored')]))!
              as List<Object?>)
        '$tag',
    ]..sort();
    return [
      for (final tag in tags)
        {
          'tag': tag,
          'count': await client.command(['ZCARD', _key('tag:$tag')]),
        },
    ];
  }

  @override
  Future<List<RecordedJob>> tagged(String tag, {int limit = 50}) async => _jobs(
    (await client.command([
          'ZRANGE',
          _key('tag:$tag'),
          '0',
          '${limit - 1}',
          'REV',
        ]))!
        as List<Object?>,
  );

  @override
  Future<void> snapshot() => _outside(() async {
    // The series to extend: the known ones and those with jobs since the
    // last snapshot. Their keys go through KEYS; a name that appears in
    // between keeps its counts for the next snapshot.
    final names = <(String, String)>{};
    for (final kind in ['job', 'queue']) {
      for (final name
          in (await client.command(['SMEMBERS', _key('snap:known:$kind')]))!
              as List<Object?>) {
        names.add((kind, '$name'));
      }
    }
    for (final field
        in (await client.command(['HKEYS', _key('snap:pending')]))!
            as List<Object?>) {
      final match = RegExp(r'^(job|queue)\|(.*)$').firstMatch('$field');
      if (match != null) {
        names.add((match[1]!, match[2]!));
      }
    }
    if (names.isEmpty) {
      return;
    }
    final keys = [
      _key('snap:pending'),
      _key('snap:known:job'),
      _key('snap:known:queue'),
    ];
    final items = [
      for (final (kind, name) in names)
        {
          'kind': kind,
          'name': name,
          'series': (keys..add(_key('snap:$kind:$name'))).length,
        },
    ];
    await client.eval(
      _snapshotScript,
      keys: keys,
      args: [
        _now,
        maxSnapshots,
        failedRetention.inMilliseconds,
        jsonEncode(items),
      ],
    );
  });

  @override
  Future<Map<String, Object?>> metrics() async {
    final out = <String, Object?>{};
    for (final (kind, into) in [('job', 'jobs'), ('queue', 'queues')]) {
      final names = [
        for (final name
            in (await client.command(['SMEMBERS', _key('snap:known:$kind')]))!
                as List<Object?>)
          '$name',
      ]..sort();
      out[into] = {
        for (final name in names)
          name: [
            for (final entry
                in ((await client.command([
                          'LRANGE',
                          _key('snap:$kind:$name'),
                          '0',
                          '-1',
                        ]))!
                        as List<Object?>)
                    .reversed)
              jsonDecode('$entry'),
          ],
      };
    }
    return out;
  }
}

/// KEYS: 1 monitored, 2 recent, 3 snap:pending, then each status list
/// (cfg.lists: status -> index), then per record its job hash, its
/// second, minute and hour buckets and its tag lists (record.k).
/// ARGV: 1 now, 2 cfg (lists, max, ttl), 3 records. Returns the uuids the
/// lists dropped, whose hashes the caller forgets.
final RedisScript _recordScript = RedisScript(r'''
local now = tonumber(ARGV[1])
local cfg = cjson.decode(ARGV[2])
local records = cjson.decode(ARGV[3])
local recent = KEYS[2]
local snap = KEYS[3]
local function bump(key, field, by, ttl)
  redis.call('HINCRBY', key, field, by)
  redis.call('PEXPIRE', key, ttl)
end
for _, r in ipairs(records) do
  local job = KEYS[r.k.job]
  local old = redis.call('HMGET', job, 'at', 'status', 'counted')
  local oldAt = tonumber(old[1] or '-1')
  local counted = old[3] or '|'
  local listed = r.at >= oldAt
  if not string.find(counted, '|' .. r.status .. '|', 1, true) then
    counted = counted .. r.status .. '|'
    local s = KEYS[r.k.s]
    bump(s, 'all', 1, 120000)
    bump(s, 'q|' .. r.queue, 1, 120000)
    if r.dur ~= cjson.null and r.dur ~= nil then
      bump(s, 'ms|' .. r.queue, r.dur, 120000)
      bump(s, 'msn|' .. r.queue, 1, 120000)
      bump(snap, 'jobms|' .. r.name, r.dur, 86400000)
      bump(snap, 'jobmsn|' .. r.name, 1, 86400000)
      bump(snap, 'queuems|' .. r.queue, r.dur, 86400000)
      bump(snap, 'queuemsn|' .. r.queue, 1, 86400000)
    end
    bump(snap, 'job|' .. r.name, 1, 86400000)
    bump(snap, 'queue|' .. r.queue, 1, 86400000)
    bump(KEYS[r.k.m], 'all', 1, 7200000)
    if r.status == 'failed' then
      bump(KEYS[r.k.h], 'failed', 1, cfg.ttl.failed + 3600000)
    end
  end
  if listed then
    redis.call('HSET', job, 'record', r.record, 'at', r.at,
      'status', r.status, 'counted', counted, 'tags', r.tagsJson)
    local before = old[2]
    if before and before ~= r.status and cfg.lists[before] then
      redis.call('ZREM', KEYS[cfg.lists[before]], r.uuid)
    end
    redis.call('ZADD', KEYS[cfg.lists[r.status]], r.at, r.uuid)
    redis.call('ZADD', recent, r.at, r.uuid)
    local keep = cfg.ttl[r.status] or cfg.ttl.recent
    for i, t in ipairs(r.k.tags) do
      if redis.call('SISMEMBER', KEYS[1], r.tags[i]) == 1 then
        redis.call('ZADD', KEYS[t], r.at, r.uuid)
        redis.call('PEXPIRE', KEYS[t], cfg.ttl.monitored)
        if cfg.ttl.monitored > keep then keep = cfg.ttl.monitored end
      end
    end
    redis.call('PEXPIRE', job, keep)
  else
    redis.call('HSET', job, 'counted', counted)
  end
end
local gone = {}
local function trim(key, ttl)
  redis.call('ZREMRANGEBYSCORE', key, '-inf', now - ttl)
  local n = redis.call('ZCARD', key)
  if n > cfg.max then
    for _, id in ipairs(redis.call('ZRANGE', key, 0, n - cfg.max - 1)) do
      table.insert(gone, id)
    end
    redis.call('ZREMRANGEBYRANK', key, 0, n - cfg.max - 1)
  end
  if n > 0 then redis.call('PEXPIRE', key, ttl) end
end
for status, index in pairs(cfg.lists) do
  trim(KEYS[index], cfg.ttl[status] or cfg.ttl.recent)
end
trim(recent, cfg.ttl.recent)
return gone
''');

/// KEYS: 1 recent, 2..lists the status lists, then per item its job hash
/// and its tag lists. ARGV: 1 {lists, items}. Deletes each job hash that
/// no list refers to, in the same script as the check.
final RedisScript _forgetScript = RedisScript(r'''
local cfg = cjson.decode(ARGV[1])
local deleted = 0
for _, item in ipairs(cfg.items) do
  local kept = false
  for i = 1, cfg.lists do
    if redis.call('ZSCORE', KEYS[i], item.uuid) then kept = true break end
  end
  if not kept then
    for _, t in ipairs(item.tags) do
      if redis.call('ZSCORE', KEYS[t], item.uuid) then kept = true break end
    end
  end
  if not kept then
    deleted = deleted + redis.call('DEL', KEYS[item.job])
  end
end
return deleted
''');

/// KEYS: the buckets; ARGV: the fields. Returns each field's sum.
final RedisScript _sumScript = RedisScript(r'''
local sums = {}
for i = 1, #ARGV do sums[i] = 0 end
for _, key in ipairs(KEYS) do
  local values = redis.call('HMGET', key, unpack(ARGV))
  for i = 1, #ARGV do
    if values[i] then sums[i] = sums[i] + tonumber(values[i]) end
  end
end
return sums
''');

/// KEYS: 1 snap:pending, 2 snap:known:job, 3 snap:known:queue, then each
/// series. ARGV: 1 now, 2 kept per series, 3 ttl, 4 items (kind, name,
/// series index). Takes, for each series, what happened since the last
/// snapshot (removing those fields only) and adds a point, 0 for a series
/// with no job since.
final RedisScript _snapshotScript = RedisScript(r'''
local now = tonumber(ARGV[1])
local keep = tonumber(ARGV[2])
local ttl = tonumber(ARGV[3])
local items = cjson.decode(ARGV[4])
for _, item in ipairs(items) do
  local f = { item.kind .. '|' .. item.name, item.kind .. 'ms|' .. item.name,
    item.kind .. 'msn|' .. item.name }
  local v = redis.call('HMGET', KEYS[1], f[1], f[2], f[3])
  redis.call('HDEL', KEYS[1], f[1], f[2], f[3])
  local count = tonumber(v[1] or '0')
  local n = tonumber(v[3] or '0')
  local avg = cjson.null
  if n > 0 then avg = tonumber(v[2]) / n end
  local known = KEYS[item.kind == 'job' and 2 or 3]
  redis.call('SADD', known, item.name)
  redis.call('PEXPIRE', known, ttl)
  local series = KEYS[item.series]
  redis.call('LPUSH', series,
    cjson.encode({at = now, count = count, avg_ms = avg}))
  redis.call('LTRIM', series, 0, keep - 1)
  redis.call('PEXPIRE', series, ttl)
end
return #items
''');
