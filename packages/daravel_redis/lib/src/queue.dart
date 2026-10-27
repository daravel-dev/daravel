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
final class RedisQueue implements WakeableQueueDriver {
  RedisQueue(
    this.client, {
    this.prefix = '',
    this.namespace = 'daravel',
    this.retryAfter = const Duration(seconds: 90),
    this.engine = RedisQueueEngine.list,
  });

  final RedisClient client;
  final String prefix;
  final String namespace;
  final Duration retryAfter;
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
    final reply = _stream
        ? await client.eval(
            _streamPop,
            keys: [_list(queue), _delayed(queue)],
            args: [_now, retryAfter.inMilliseconds, _jobPrefix(queue), _group],
          )
        : await client.eval(
            _pop,
            keys: [_list(queue), _delayed(queue), _reserved(queue)],
            args: [_now, retryAfter.inMilliseconds, _jobPrefix(queue)],
          );
    if (reply is! List || reply.length < 3) {
      return null;
    }
    final raw = reply[1]! as String;
    return QueuedJob(
      id: reply[0]! as String,
      queue: queue,
      payload: JobPayload.decode(raw),
      attempts: reply[2]! as int,
      raw: raw,
    );
  }

  static final RedisScript _release = RedisScript('''
if ARGV[4] == 'stream' then
  local entry = redis.call('HGET', KEYS[5], 'entry')
  if entry then
    redis.call('XACK', KEYS[1], ARGV[5], entry)
    redis.call('XDEL', KEYS[1], entry)
  end
else
  redis.call('ZREM', KEYS[3], ARGV[1])
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
    await client.eval(
      _release,
      keys: [
        _list(job.queue),
        _delayed(job.queue),
        _reserved(job.queue),
        _notify(job.queue),
        '${_jobPrefix(job.queue)}${job.id}',
      ],
      args: [job.id, now + delay.inMilliseconds, now, engine.name, _group],
    );
  }

  static final RedisScript _streamDelete = RedisScript('''
local entry = redis.call('HGET', KEYS[2], 'entry')
if entry then
  redis.call('XACK', KEYS[1], ARGV[1], entry)
  redis.call('XDEL', KEYS[1], entry)
end
return redis.call('DEL', KEYS[2])''');

  @override
  Future<void> delete(QueuedJob job) async {
    if (_stream) {
      await client.eval(
        _streamDelete,
        keys: [_list(job.queue), '${_jobPrefix(job.queue)}${job.id}'],
        args: [_group],
      );
      return;
    }
    await (
      client.command(['ZREM', _reserved(job.queue), job.id]),
      client.del(['${_jobPrefix(job.queue)}${job.id}']),
    ).wait;
  }

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
    } on RedisCommandException {
      // A slot moved (MOVED) or the server refused: another connection
      // next time, after a pause so a lasting error does not spin.
      await _blocking.remove(slot)?.close();
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
