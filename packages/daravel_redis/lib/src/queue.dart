import 'dart:async';
import 'dart:math';

import 'package:daravel/daravel.dart';

import 'client.dart';
import 'connection.dart';
import 'resp.dart';

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
/// | Key | Holds |
/// | :-- | :-- |
/// | `<ns>:queue:{q}` | ids of jobs ready to run (list) |
/// | `<ns>:queue:{q}:delayed` | ids by the time they become ready (zset) |
/// | `<ns>:queue:{q}:reserved` | ids being run, by when they expire (zset) |
/// | `<ns>:queue:{q}:notify` | tokens that wake waiting workers (list) |
/// | `<ns>:queue:{q}:job:<id>` | `payload`, `attempts`, `available_at` (hash) |
///
/// Delivery is at least once: a reserved job not deleted within
/// [retryAfter] runs again, as with the database queue.
final class RedisQueue implements WakeableQueueDriver {
  RedisQueue(
    this.client, {
    this.prefix = '',
    this.namespace = 'daravel',
    this.retryAfter = const Duration(seconds: 90),
  });

  final RedisClient client;
  final String prefix;
  final String namespace;
  final Duration retryAfter;

  @override
  String get name => 'redis';

  @override
  StateScope get scope => StateScope.cluster;

  static int get _now => Clock.now().toUtc().millisecondsSinceEpoch;

  String _list(String queue) => '$prefix$namespace:queue:{$queue}';
  String _delayed(String queue) => '${_list(queue)}:delayed';
  String _reserved(String queue) => '${_list(queue)}:reserved';
  String _notify(String queue) => '${_list(queue)}:notify';
  String _jobPrefix(String queue) => '${_list(queue)}:job:';

  static final RedisScript _push = RedisScript('''
redis.call('HSET', KEYS[4], 'payload', ARGV[2], 'attempts', 0, 'available_at', ARGV[4])
if tonumber(ARGV[4]) > tonumber(ARGV[3]) then
  redis.call('ZADD', KEYS[2], ARGV[4], ARGV[1])
else
  redis.call('RPUSH', KEYS[1], ARGV[1])
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
      args: [id, payload.encode(), now, now + (delay?.inMilliseconds ?? 0)],
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

  @override
  Future<QueuedJob?> pop(String queue) async {
    final reply = await client.eval(
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
redis.call('ZREM', KEYS[3], ARGV[1])
redis.call('HSET', KEYS[5], 'available_at', ARGV[2])
if tonumber(ARGV[2]) > tonumber(ARGV[3]) then
  redis.call('ZADD', KEYS[2], ARGV[2], ARGV[1])
else
  redis.call('RPUSH', KEYS[1], ARGV[1])
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
      args: [job.id, now + delay.inMilliseconds, now],
    );
  }

  @override
  Future<void> delete(QueuedJob job) async {
    await (
      client.command(['ZREM', _reserved(job.queue), job.id]),
      client.del(['${_jobPrefix(job.queue)}${job.id}']),
    ).wait;
  }

  @override
  Future<int> size(String queue) async {
    final (ready, delayed, reserved) = await (
      client.command(['LLEN', _list(queue)]),
      client.command(['ZCARD', _delayed(queue)]),
      client.command(['ZCARD', _reserved(queue)]),
    ).wait;
    return (ready! as int) + (delayed! as int) + (reserved! as int);
  }

  @override
  Future<Duration?> oldestWait(String queue) async {
    final id = await client.command(['LINDEX', _list(queue), 0]);
    if (id is! String) {
      return null;
    }
    final available = await client.command([
      'HGET',
      '${_jobPrefix(queue)}$id',
      'available_at',
    ]);
    final since = int.tryParse('$available');
    return since == null ? null : Duration(milliseconds: max(0, _now - since));
  }

  static final RedisScript _clear = RedisScript('''
local ids = redis.call('LRANGE', KEYS[1], 0, -1)
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
            args: [_jobPrefix(queue)],
          ))!
          as int;

  // -------------------------------------------------------------------
  // Waking idle workers.

  RedisConnection? _blocking;

  /// `BLPOP` on the queues' notify lists, on a connection of its own, for
  /// [maxWait] at most and no longer than until the next delayed job is
  /// due, so that one runs on time.
  @override
  Future<void> waitForWork(List<String> queues, Duration maxWait) async {
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
    try {
      final blocking = _blocking ??= await client.dedicated();
      await blocking.send([
        'BLPOP',
        ...queues.map(_notify),
        // Seconds, with decimals (Redis 6+); never 0, which blocks forever.
        max(0.01, wait.inMilliseconds / 1000).toStringAsFixed(3),
      ], timeout: wait + const Duration(seconds: 5));
    } on RedisConnectionException {
      // Stopped, or the connection dropped: open another next time.
      _blocking = null;
    }
  }

  @override
  Future<void> stopWaiting() async {
    final blocking = _blocking;
    _blocking = null;
    await blocking?.close();
  }
}
