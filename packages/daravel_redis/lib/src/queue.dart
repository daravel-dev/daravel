import 'dart:async';
import 'dart:math';

import 'package:daravel/daravel.dart';

import 'client.dart';
import 'connection.dart';
import 'resp.dart';

/// How [RedisQueue] keeps its jobs (`QUEUE_REDIS_ENGINE`).
enum RedisQueueEngine {
  /// Lists and sorted sets, on any Redis or Valkey.
  list,

  /// A stream with a consumer group (Redis 6.2 or Valkey 7.2 and later):
  /// the server tracks the jobs being run (`XPENDING`) and hands those whose
  /// worker died to another (`XAUTOCLAIM`).
  stream,
}

/// `QUEUE_CONNECTION=redis`: jobs in Redis, picked up by workers on every
/// server as soon as they are pushed (`BLPOP`, no polling).
///
/// Keys share the hash tag of their queue (`{default}`), so each script
/// touches one Redis Cluster slot. A job's payload lives in a hash, apart
/// from its attempts, so it stays byte for byte what [JobPayload.encode]
/// wrote (Lua never rewrites it). The namespace (`daravel:`) keeps these
/// queues apart from Laravel's `queues:`, whose workers cannot run Daravel
/// jobs.
///
/// | Key ([RedisQueueEngine.list]) | Holds |
/// | :-- | :-- |
/// | `<ns>:queue:{q}` | ids of jobs ready to run (list) |
/// | `<ns>:queue:{q}:delayed` | ids by the time they become ready (zset) |
/// | `<ns>:queue:{q}:reserved` | ids being run, by when they expire (zset) |
/// | `<ns>:queue:{q}:notify` | tokens that wake waiting workers (list) |
/// | `<ns>:queue:{q}:job:<id>` | `payload`, `attempts`, `available_at` (hash) |
///
/// [RedisQueueEngine.stream] keeps the same under `<ns>:stream:{q}`, a
/// stream of job ids read by the consumer group `daravel`, without the
/// reserved set: a job read and not acknowledged within [retryAfter] (by
/// the server's clock) is claimed again.
///
/// Delivery is at least once: a reserved job not deleted within
/// [retryAfter] runs again, as with the database queue.
final class RedisQueue
    implements
        WakeableQueueDriver,
        ExtendingQueueDriver,
        BrowsableQueueDriver,
        ReclaimableQueueDriver,
        OwnershipQueueDriver {
  /// A queue in Redis, as Laravel's `redis` queue driver.
  RedisQueue(
    this.client, {
    this.prefix = '',
    this.namespace = 'daravel',
    this.retryAfter = const Duration(seconds: 90),
    this.engine = RedisQueueEngine.list,
    this.logger,
  });

  /// Where an unexpected error of the blocking wait is told (at most once a
  /// second); none when null.
  final Logger? logger;

  /// When an unexpected wait error was last logged (wall clock).
  DateTime? _waitErrorLogged;

  /// The Redis connection.
  final RedisClient client;

  /// The key prefix.
  final String prefix;

  /// The queue namespace, shared with Laravel when equal.
  final String namespace;

  /// How long a reserved job may run before another worker takes it.
  @override
  final Duration retryAfter;

  /// Lists (Laravel's layout) or streams.
  final RedisQueueEngine engine;

  bool get _stream => engine == RedisQueueEngine.stream;

  /// The consumer group (and consumer) of [RedisQueueEngine.stream].
  static const String _group = 'daravel';

  @override
  String get name => 'redis';

  @override
  StateScope get scope => StateScope.cluster;

  static int get _now => Clock.now().toUtc().millisecondsSinceEpoch;

  String _list(String queue) =>
      '$prefix$namespace:${_stream ? 'stream' : 'queue'}:{$queue}';
  String _delayed(String queue) => '${_list(queue)}:delayed';
  String _reserved(String queue) => '${_list(queue)}:reserved';
  String _notify(String queue) => '${_list(queue)}:notify';
  String _jobPrefix(String queue) => '${_list(queue)}:job:';

  static final RedisScript _push = RedisScript('''
redis.call('HSET', KEYS[4], 'payload', ARGV[2], 'attempts', 0, 'available_at', ARGV[4])
if tonumber(ARGV[4]) > tonumber(ARGV[3]) then
  redis.call('ZADD', KEYS[2], ARGV[4], ARGV[1])
else
  if ARGV[5] == 'stream' then
    redis.call('XADD', KEYS[1], '*', 'id', ARGV[1])
  else
    redis.call('RPUSH', KEYS[1], ARGV[1])
  end
  redis.call('RPUSH', KEYS[3], 1)
  redis.call('LTRIM', KEYS[3], -100, -1)
end
return 1''');

  @override
  Future<Object> push(
    JobPayload payload, {
    required String queue,
    Duration? delay,
  }) async {
    final id = payload.uuid;
    final now = _now;
    await client.eval(
      _push,
      keys: [
        _list(queue),
        _delayed(queue),
        _notify(queue),
        '${_jobPrefix(queue)}$id',
      ],
      args: [
        id,
        payload.encode(),
        now,
        now + (delay?.inMilliseconds ?? 0),
        engine.name,
      ],
    );
    return id;
  }

  /// Moves due delayed jobs and expired reservations to the list, then
  /// reserves the first job.
  static final RedisScript _pop = RedisScript('''
local now = tonumber(ARGV[1])
for _, set in ipairs({KEYS[2], KEYS[3]}) do
  local due = redis.call('ZRANGEBYSCORE', set, '-inf', now, 'LIMIT', 0, 100)
  for _, id in ipairs(due) do
    redis.call('ZREM', set, id)
    redis.call('RPUSH', KEYS[1], id)
  end
end
local id = redis.call('LPOP', KEYS[1])
while id do
  local job = ARGV[3] .. id
  if redis.call('EXISTS', job) == 1 then
    local attempts = redis.call('HINCRBY', job, 'attempts', 1)
    redis.call('ZADD', KEYS[3], now + tonumber(ARGV[2]), id)
    return {id, redis.call('HGET', job, 'payload'), attempts}
  end
  id = redis.call('LPOP', KEYS[1])
end
return false''');

  /// Moves due delayed jobs to the stream, then claims a job whose
  /// reservation expired or reads a new one, and records its entry.
  static final RedisScript _streamPop = RedisScript('''
redis.pcall('XGROUP', 'CREATE', KEYS[1], ARGV[4], '0', 'MKSTREAM')
local due = redis.call('ZRANGEBYSCORE', KEYS[2], '-inf', ARGV[1], 'LIMIT', 0, 100)
for _, id in ipairs(due) do
  redis.call('ZREM', KEYS[2], id)
  redis.call('XADD', KEYS[1], '*', 'id', id)
end
for _ = 1, 100 do
  local entry
  local claimed = redis.call('XAUTOCLAIM', KEYS[1], ARGV[4], ARGV[4], ARGV[2], '0-0', 'COUNT', 1)
  if claimed[2][1] then
    entry = claimed[2][1]
  else
    local read = redis.call('XREADGROUP', 'GROUP', ARGV[4], ARGV[4], 'COUNT', 1, 'STREAMS', KEYS[1], '>')
    if read then
      entry = read[1][2][1]
    end
  end
  if not entry then
    return false
  end
  local job = entry[2] and (ARGV[3] .. entry[2][2])
  if job and redis.call('EXISTS', job) == 1 then
    local attempts = redis.call('HINCRBY', job, 'attempts', 1)
    redis.call('HSET', job, 'entry', entry[1])
    return {entry[2][2], redis.call('HGET', job, 'payload'), attempts}
  end
  redis.call('XACK', KEYS[1], ARGV[4], entry[1])
  redis.call('XDEL', KEYS[1], entry[1])
end
return false''');

  @override
  Future<QueuedJob?> pop(String queue) async {
    final now = _now;
    final reply = _stream
        ? await client.eval(
            _streamPop,
            keys: [_list(queue), _delayed(queue)],
            args: [now, retryAfter.inMilliseconds, _jobPrefix(queue), _group],
          )
        : await client.eval(
            _pop,
            keys: [_list(queue), _delayed(queue), _reserved(queue)],
            args: [now, retryAfter.inMilliseconds, _jobPrefix(queue)],
          );
    if (reply is! List || reply.length < 3) {
      return null;
    }
    final id = reply[0]! as String;
    final attempts = reply[2]! as int;
    // A hash without its payload (one a release made for a job already
    // deleted, before 1.28.0) reads as false.
    final raw = reply[1] is String ? reply[1]! as String : '';
    final JobPayload payload;
    try {
      payload = JobPayload.decode(raw);
    } on Object catch (error) {
      // A payload that does not decode would stay reserved and be popped
      // again after every retry_after, for ever. It is removed here, and
      // the worker records it in failed_jobs, as with the database queue.
      await _remove(queue, id, attempts);
      throw CorruptPayloadException(
        id: id,
        queue: queue,
        raw: raw,
        cause: error,
      );
    }
    // List engine: the reservation's score is s = now + R (R =
    // retryAfter in ms), and a pop at m moves it back only once s <= m
    // (ZRANGEBYSCORE -inf m), that is m >= now + R: never before, on the
    // clock of the process that pops next. Stream engine: XAUTOCLAIM takes
    // an entry idle for R ms on the Redis server's clock, counted from its
    // delivery, which is not before now on a server whose clock runs with
    // this process's; a server clock that runs fast or jumps ahead (Docker
    // on WSL 2 was measured jumping 1.45 s) takes it back earlier.
    return QueuedJob(
      id: id,
      queue: queue,
      payload: payload,
      attempts: attempts,
      raw: raw,
      reservedUntil: DateTime.fromMillisecondsSinceEpoch(
        now + retryAfter.inMilliseconds,
        isUtc: true,
      ),
    );
  }

  /// Puts a job back, only for the worker that still holds its
  /// reservation: the job's `attempts` (which every reservation raises)
  /// must be the worker's (ARGV 6), and the reservation must still be
  /// there (a `:reserved` member, or a pending stream entry: `XACK` says
  /// 1, and the hash's `entry` field goes with it). Otherwise 0 and
  /// nothing changes: no hash made for a job another worker deleted, no
  /// second copy queued, no other worker's reservation taken away.
  static final RedisScript _release = RedisScript('''
if redis.call('HGET', KEYS[5], 'attempts') ~= ARGV[6] then
  return 0
end
if ARGV[4] == 'stream' then
  local entry = redis.call('HGET', KEYS[5], 'entry')
  if not entry or redis.call('XACK', KEYS[1], ARGV[5], entry) == 0 then
    return 0
  end
  redis.call('XDEL', KEYS[1], entry)
  redis.call('HDEL', KEYS[5], 'entry')
elseif redis.call('ZREM', KEYS[3], ARGV[1]) == 0 then
  return 0
end
redis.call('HSET', KEYS[5], 'available_at', ARGV[2])
if tonumber(ARGV[2]) > tonumber(ARGV[3]) then
  redis.call('ZADD', KEYS[2], ARGV[2], ARGV[1])
else
  if ARGV[4] == 'stream' then
    redis.call('XADD', KEYS[1], '*', 'id', ARGV[1])
  else
    redis.call('RPUSH', KEYS[1], ARGV[1])
  end
  redis.call('RPUSH', KEYS[4], 1)
  redis.call('LTRIM', KEYS[4], -100, -1)
end
return 1''');

  @override
  Future<void> release(QueuedJob job, Duration delay) async {
    final now = _now;
    final done = await client.eval(
      _release,
      keys: [
        _list(job.queue),
        _delayed(job.queue),
        _reserved(job.queue),
        _notify(job.queue),
        '${_jobPrefix(job.queue)}${job.id}',
      ],
      args: [
        job.id,
        now + delay.inMilliseconds,
        now,
        engine.name,
        _group,
        '${job.attempts}',
      ],
    );
    if (done != 1) {
      _notOwner(job, 'release');
    }
  }

  /// The jobs [_notOwner] warned about, newest last, so each is told once.
  final List<String> _warned = <String>[];

  /// Warns, once per job, that a worker acted on a job it no longer held:
  /// it ran past `retry_after` and another worker took it. The guard
  /// prevents the damage (a deleted or doubled job); the job still ran
  /// twice, which a longer `retry_after` (above the longest job, as in
  /// Laravel) prevents.
  void _notOwner(QueuedJob job, String action) {
    final key = '${job.queue}:${job.id}';
    if (_warned.contains(key)) {
      return;
    }
    _warned.add(key);
    if (_warned.length > 1000) {
      _warned.removeAt(0);
    }
    logger?.warning(
      'Job ${job.id} on queue [${job.queue}] ran past retry_after: another '
      'worker took it, so its $action did nothing. Raise retry_after above '
      'the longest job.',
    );
  }

  /// Extends a reservation that is still the worker's own (the job's
  /// `attempts` grow with every reservation): the reserved score, or the
  /// stream entry's idle time (`XCLAIM ... JUSTID`, which leaves the
  /// delivery count alone). Returns 1 when the reservation moved, 0 when
  /// it is no longer the worker's: a job taken back to the list (`ZADD XX
  /// CH` counts no change for a member it did not find) or an entry no
  /// longer pending.
  static final RedisScript _touch = RedisScript('''
if redis.call('HGET', KEYS[2], 'attempts') ~= ARGV[3] then
  return 0
end
if ARGV[4] == 'stream' then
  local entry = redis.call('HGET', KEYS[2], 'entry')
  if not entry then
    return 0
  end
  return #redis.call('XCLAIM', KEYS[1], ARGV[5], ARGV[5], 0, entry, 'JUSTID')
end
return redis.call('ZADD', KEYS[3], 'XX', 'CH', ARGV[1], ARGV[2])''');

  @override
  Future<void> touch(QueuedJob job) => extend(job);

  /// [touch], and the new reservation's end: now plus [retryAfter] to the
  /// millisecond (the list engine's score; the stream engine resets the
  /// entry's idle time on the Redis server's clock, as for a pop).
  @override
  Future<DateTime?> extend(QueuedJob job) async {
    final until = _now + retryAfter.inMilliseconds;
    final done = await client.eval(
      _touch,
      keys: [
        _list(job.queue),
        '${_jobPrefix(job.queue)}${job.id}',
        _reserved(job.queue),
      ],
      args: [until, job.id, '${job.attempts}', engine.name, _group],
    );
    return done == 1
        ? DateTime.fromMillisecondsSinceEpoch(until, isUtc: true)
        : null;
  }

  /// Deletes a job, only for the worker that still holds it (its
  /// `attempts`, ARGV 2), in one step: the reservation (or stream entry)
  /// and the hash. 0 when another worker holds it now.
  static final RedisScript _delete = RedisScript('''
if redis.call('HGET', KEYS[2], 'attempts') ~= ARGV[2] then
  return 0
end
if ARGV[3] == 'stream' then
  local entry = redis.call('HGET', KEYS[2], 'entry')
  if entry then
    redis.call('XACK', KEYS[1], ARGV[4], entry)
    redis.call('XDEL', KEYS[1], entry)
  end
else
  redis.call('ZREM', KEYS[3], ARGV[1])
end
redis.call('DEL', KEYS[2])
return 1''');

  @override
  Future<void> delete(QueuedJob job) async {
    await deleteOwned(job);
  }

  @override
  Future<bool> deleteOwned(QueuedJob job) async {
    final removed = await _remove(job.queue, '${job.id}', job.attempts);
    if (!removed) {
      _notOwner(job, 'delete');
    }
    return removed;
  }

  /// Whether the job's hash still holds [job]'s `attempts`: every
  /// reservation raises them.
  @override
  Future<bool> owns(QueuedJob job) async =>
      await client.command([
        'HGET',
        '${_jobPrefix(job.queue)}${job.id}',
        'attempts',
      ]) ==
      '${job.attempts}';

  /// Removes job [id] reserved with [attempts]; whether it was.
  Future<bool> _remove(String queue, String id, int attempts) async =>
      await client.eval(
        _delete,
        keys: [_list(queue), '${_jobPrefix(queue)}$id', _reserved(queue)],
        args: [id, '$attempts', engine.name, _group],
      ) ==
      1;

  @override
  Future<int> size(String queue) async {
    if (_stream) {
      // Entries stay in the stream until deleted: ready and running jobs.
      final (entries, delayed) = await (
        client.command(['XLEN', _list(queue)]),
        client.command(['ZCARD', _delayed(queue)]),
      ).wait;
      return (entries! as int) + (delayed! as int);
    }
    final (ready, delayed, reserved) = await (
      client.command(['LLEN', _list(queue)]),
      client.command(['ZCARD', _delayed(queue)]),
      client.command(['ZCARD', _reserved(queue)]),
    ).wait;
    return (ready! as int) + (delayed! as int) + (reserved! as int);
  }

  /// The first entry the group has not read yet, and its job's
  /// `available_at`.
  static final RedisScript _streamOldest = RedisScript('''
local last = '0-0'
local groups = redis.pcall('XINFO', 'GROUPS', KEYS[1])
if type(groups) == 'table' and not groups.err then
  for _, group in ipairs(groups) do
    local fields = {}
    for i = 1, #group, 2 do
      fields[group[i]] = group[i + 1]
    end
    if fields['name'] == ARGV[1] then
      last = fields['last-delivered-id']
    end
  end
end
local next
if last == '0-0' then
  next = redis.pcall('XRANGE', KEYS[1], '-', '+', 'COUNT', 1)
else
  next = redis.pcall('XRANGE', KEYS[1], '(' .. last, '+', 'COUNT', 1)
end
if type(next) ~= 'table' or next.err or not next[1] or not next[1][2] then
  return false
end
return redis.call('HGET', ARGV[2] .. next[1][2][2], 'available_at')''');

  @override
  Future<Duration?> oldestWait(String queue) async {
    Object? available;
    if (_stream) {
      available = await client.eval(
        _streamOldest,
        keys: [_list(queue)],
        args: [_group, _jobPrefix(queue)],
      );
    } else {
      final id = await client.command(['LINDEX', _list(queue), 0]);
      if (id is! String) {
        return null;
      }
      available = await client.command([
        'HGET',
        '${_jobPrefix(queue)}$id',
        'available_at',
      ]);
    }
    final since = available is String ? int.tryParse(available) : null;
    return since == null ? null : Duration(milliseconds: max(0, _now - since));
  }

  static final RedisScript _clear = RedisScript('''
local ids = {}
if ARGV[2] == 'stream' then
  for _, entry in ipairs(redis.call('XRANGE', KEYS[1], '-', '+')) do
    if entry[2] then
      table.insert(ids, entry[2][2])
    end
  end
else
  ids = redis.call('LRANGE', KEYS[1], 0, -1)
end
for _, set in ipairs({KEYS[2], KEYS[3]}) do
  for _, id in ipairs(redis.call('ZRANGE', set, 0, -1)) do
    table.insert(ids, id)
  end
end
for _, id in ipairs(ids) do
  redis.call('DEL', ARGV[1] .. id)
end
redis.call('DEL', KEYS[1], KEYS[2], KEYS[3], KEYS[4])
return #ids''');

  @override
  Future<int> clear(String queue) async =>
      (await client.eval(
            _clear,
            keys: [
              _list(queue),
              _delayed(queue),
              _reserved(queue),
              _notify(queue),
            ],
            args: [_jobPrefix(queue), engine.name],
          ))!
          as int;

  // -------------------------------------------------------------------
  // Browsing and reclaiming (daravel_horizon).

  /// The jobs of a page of ids: `{id, payload, attempts, available_at}`
  /// for each id whose hash still exists. `ARGV[1]`/`ARGV[2]` bound the
  /// page; `ARGV[3]` is the job hash prefix; `ARGV[4]` picks the source:
  /// `list` (ready ids of the list engine), `zset` (the delayed set) or
  /// `stream` (entries the consumer group has not read yet).
  static final RedisScript _browse = RedisScript('''
local first, last = tonumber(ARGV[1]), tonumber(ARGV[2])
local ids = {}
if ARGV[4] == 'list' then
  ids = redis.call('LRANGE', KEYS[1], first, last)
elseif ARGV[4] == 'zset' then
  ids = redis.call('ZRANGE', KEYS[1], first, last)
else
  local after = '-'
  local groups = redis.pcall('XINFO', 'GROUPS', KEYS[1])
  if type(groups) == 'table' and not groups.err then
    for _, group in ipairs(groups) do
      local fields = {}
      for i = 1, #group, 2 do
        fields[group[i]] = group[i + 1]
      end
      if fields['name'] == ARGV[5] and fields['last-delivered-id'] ~= '0-0' then
        after = '(' .. fields['last-delivered-id']
      end
    end
  end
  local entries = redis.pcall('XRANGE', KEYS[1], after, '+', 'COUNT', last + 1)
  if type(entries) == 'table' and not entries.err then
    for i = first + 1, #entries do
      if entries[i][2] then
        table.insert(ids, entries[i][2][2])
      end
    end
  end
end
local out = {}
for _, id in ipairs(ids) do
  local job = redis.call('HMGET', ARGV[3] .. id, 'payload', 'attempts', 'available_at')
  if job[1] then
    table.insert(out, {id, job[1], job[2] or '0', job[3] or '0'})
  end
end
return out''');

  /// Ready jobs: the list in pop order, or the stream entries the group
  /// has not read yet. Due delayed jobs and expired reservations are moved
  /// to the list by the next pop, so they show under [delayed] until then.
  @override
  Future<List<QueuedJobView>> pending(
    String queue, {
    int limit = 50,
    int offset = 0,
  }) => _views(queue, _list(queue), _stream ? 'stream' : 'list', limit, offset);

  /// Delayed jobs, by the time they become ready.
  @override
  Future<List<QueuedJobView>> delayed(
    String queue, {
    int limit = 50,
    int offset = 0,
  }) => _views(queue, _delayed(queue), 'zset', limit, offset);

  Future<List<QueuedJobView>> _views(
    String queue,
    String key,
    String source,
    int limit,
    int offset,
  ) async {
    final skip = max(0, offset);
    if (limit <= 0) {
      return const [];
    }
    final reply = await client.eval(
      _browse,
      keys: [key],
      args: [skip, skip + limit - 1, _jobPrefix(queue), source, _group],
    );
    return [
      for (final row in reply is List ? reply : const <Object?>[])
        if (row case [
          final String id,
          final String payload,
          final Object? attempts,
          final Object? available,
        ])
          QueuedJobView.fromStored(
            id: id,
            queue: queue,
            payload: payload,
            attempts: int.tryParse('$attempts') ?? 0,
            availableAt: DateTime.fromMillisecondsSinceEpoch(
              int.tryParse('$available') ?? 0,
              isUtc: true,
            ),
          ),
    ];
  }

  /// Hands a reserved job back: on the list engine it leaves the reserved
  /// set for the end of the list; on the stream engine its pending entry is
  /// acknowledged and the id added again (as [release] does, without
  /// `XCLAIM`). `attempts` and `available_at` are left alone; waiting
  /// workers are woken.
  static final RedisScript _reclaim = RedisScript('''
if ARGV[2] == 'stream' then
  local entry = redis.call('HGET', KEYS[4], 'entry')
  if not entry then
    return 0
  end
  local pending = redis.call('XPENDING', KEYS[1], ARGV[3], entry, entry, 1)
  if not pending[1] then
    return 0
  end
  redis.call('XACK', KEYS[1], ARGV[3], entry)
  redis.call('XDEL', KEYS[1], entry)
  redis.call('HDEL', KEYS[4], 'entry')
  redis.call('XADD', KEYS[1], '*', 'id', ARGV[1])
else
  if redis.call('ZREM', KEYS[2], ARGV[1]) == 0 then
    return 0
  end
  redis.call('RPUSH', KEYS[1], ARGV[1])
end
redis.call('RPUSH', KEYS[3], 1)
redis.call('LTRIM', KEYS[3], -100, -1)
return 1''');

  @override
  Future<bool> reclaim(String queue, Object jobId) async =>
      await client.eval(
        _reclaim,
        keys: [
          _list(queue),
          _reserved(queue),
          _notify(queue),
          '${_jobPrefix(queue)}$jobId',
        ],
        args: ['$jobId', engine.name, _group],
      ) ==
      1;

  // -------------------------------------------------------------------
  // Waking idle workers.

  /// One blocking connection per hash slot of the queues' notify lists
  /// (one on a single server), and the `BLPOP` each one is waiting in.
  final Map<int?, RedisConnection> _blocking = {};
  final Map<int?, Future<void>> _waiting = {};

  /// A `BLPOP` took a token while nobody was waiting for it.
  bool _woken = false;

  /// `BLPOP` on the queues' notify lists, on connections of their own, for
  /// [maxWait] at most and no longer than until the next delayed job is
  /// due, so that one runs on time. In a cluster, queues whose lists live
  /// on different slots wait in one `BLPOP` per slot, together.
  @override
  Future<void> waitForWork(List<String> queues, Duration maxWait) async {
    if (_woken) {
      _woken = false;
      return;
    }
    var wait = maxWait;
    final now = _now;
    for (final queue in queues) {
      final next = await client.command([
        'ZRANGE',
        _delayed(queue),
        0,
        0,
        'WITHSCORES',
      ]);
      if (next case [_, final String score]) {
        final due = Duration(
          milliseconds: max(0, (double.tryParse(score) ?? 0).toInt() - now),
        );
        wait = due < wait ? due : wait;
      }
    }
    if (wait <= Duration.zero) {
      return;
    }
    final groups = <int?, List<String>>{};
    for (final queue in queues) {
      final key = _notify(queue);
      groups.putIfAbsent(client.slot(key), () => []).add(key);
    }
    // A pending BLPOP may have taken a token while the delayed jobs were
    // read; from here to Future.any nothing awaits, so a later token ends
    // a wait this call is part of.
    if (_woken) {
      _woken = false;
      return;
    }
    await Future.any([
      for (final MapEntry(key: slot, value: keys) in groups.entries)
        _waiting.putIfAbsent(slot, () => _block(slot, keys, wait)),
      Future<void>.delayed(wait),
    ]);
    _woken = false;
  }

  Future<void> _block(int? slot, List<String> keys, Duration wait) async {
    try {
      final blocking = _blocking[slot] ??= await client.dedicated(
        key: keys.first,
      );
      final token = await blocking.send([
        'BLPOP',
        ...keys,
        // Seconds, with decimals (Redis 6+); never 0, which blocks forever.
        max(0.01, wait.inMilliseconds / 1000).toStringAsFixed(3),
      ], timeout: wait + const Duration(seconds: 5));
      if (token != null) {
        _woken = true;
      }
    } on RedisConnectionException {
      // Stopped, or the connection dropped: open another next time.
      _blocking.remove(slot);
    } on Object catch (error) {
      // A slot moved (MOVED), the server refused, or anything else: another
      // connection next time, after a pause so a lasting error does not
      // spin. Never rethrown: this wait is shared by the workers waiting on
      // the slot, each in a zone of its own, which an error would not reach.
      if (error is! RedisCommandException) {
        final now = DateTime.now();
        final last = _waitErrorLogged;
        if (last == null ||
            now.difference(last) >= const Duration(seconds: 1)) {
          _waitErrorLogged = now;
          logger?.warning(
            'Redis queue wait failed (${error.runtimeType}); waiting with a '
            'new connection next time.',
          );
        }
      }
      try {
        await _blocking.remove(slot)?.close();
      } on Object {
        // Closing a broken connection: nothing more to do.
      }
      await Future<void>.delayed(
        wait < const Duration(seconds: 1) ? wait : const Duration(seconds: 1),
      );
    } finally {
      unawaited(_waiting.remove(slot)); // this very wait, done
    }
  }

  @override
  Future<void> stopWaiting() async {
    final blocking = [..._blocking.values];
    _blocking.clear();
    for (final connection in blocking) {
      await connection.close();
    }
  }
}
