import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import '../foundation/clock.dart';

import 'package:uuid/uuid.dart';

import '../database/database_manager.dart';
import '../database/orm/casts.dart';
import '../foundation/exceptions.dart';
import '../logging/context.dart';
import '../database/query/query_builder.dart';
import '../database/schema/migration.dart';
import '../database/schema/schema_builder.dart';
import '../server/coordinator.dart';
import 'job.dart';

/// JSON envelope stored by every driver. Top-level keys mirror Laravel's
/// payload (`uuid`, `displayName`, `job`, `maxTries`, …); `data` holds the
/// Dart job's own JSON, so payloads are not cross-runtime (§4.4).
final class JobPayload {
  /// A payload; [JobPayload.forJob] builds one from a job.
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
    this.debounceOwner,
    this.tags = const <String>[],
    this.context,
  });

  /// The payload of [job], with its retry settings and a new UUID.
  factory JobPayload.forJob(
    Job job, {
    String? uuid,
    DateTime? now,
    String? uniqueKey,
    String? debounceOwner,
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
      debounceOwner: debounceOwner,
      tags: List.unmodifiable(job.tags),
      // The dispatching request's Context travels with the job.
      context: Context.current.dehydrate(),
    );
  }

  /// A payload read back from its JSON.
  factory JobPayload.fromJson(Map<String, Object?> json) => JobPayload(
    uuid: json['uuid'] as String,
    jobName: json['job'] as String,
    displayName: json['displayName'] as String? ?? json['job'] as String,
    data: (json['data'] as Map<String, Object?>?) ?? const {},
    maxTries: (json['maxTries'] as num?)?.toInt() ?? 1,
    maxExceptions: (json['maxExceptions'] as num?)?.toInt(),
    failOnTimeout: json['failOnTimeout'] as bool? ?? false,
    backoffSeconds: _backoff(json['backoff']),
    timeout: Duration(
      milliseconds: (((json['timeout'] as num?) ?? 60) * 1000).round(),
    ),
    pushedAt: (json['pushedAt'] as num?)?.toInt() ?? 0,
    retryUntil: (json['retryUntil'] as num?)?.toInt(),
    uniqueKey: json['uniqueKey'] as String?,
    debounceOwner: json['debounceOwner'] as String?,
    tags: [
      for (final tag in (json['tags'] as List<Object?>?) ?? const <Object?>[])
        if (tag is String) tag,
    ],
    context: switch (json['context']) {
      final Map<Object?, Object?> map => {
        for (final MapEntry(:key, :value) in map.entries) '$key': value,
      },
      _ => null,
    },
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

  /// A unique id of this dispatch, kept across retries.
  final String uuid;

  /// The registered job name, used to rebuild the job.
  final String jobName;

  /// The name shown in logs and `queue:failed`.
  final String displayName;

  /// The job's own data, from its `toJson`.
  final Map<String, Object?> data;

  /// How many times the job may be attempted.
  final int maxTries;

  /// How many exceptions the job may throw before it fails (null: no
  /// limit beyond [maxTries]).
  final int? maxExceptions;

  /// Whether a timeout fails the job at once instead of retrying it.
  final bool failOnTimeout;

  /// The waits between attempts, in seconds.
  final List<int> backoffSeconds;

  /// Handler timeout (stored as seconds, fractional for sub-second).
  final Duration timeout;

  /// Epoch seconds of the first push.
  final int pushedAt;

  /// Epoch seconds after which no retry happens (`null` = use maxTries).
  final int? retryUntil;

  /// Unique-job lock key to release after processing.
  final String? uniqueKey;

  /// The dispatch this payload belongs to; see [Job.debounceFor].
  final String? debounceOwner;

  /// Monitoring tags ([Job.tags]; Laravel Horizon's `tags` payload key).
  /// The dispatching scope's `Context` (visible and hidden entries).
  final Map<String, Object?>? context;

  /// Tags shown by monitoring tools.
  final List<String> tags;

  /// The payload as JSON, as stored in the `jobs` table.
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
    if (debounceOwner != null) 'debounceOwner': debounceOwner,
    'tags': tags,
    if (context != null) 'context': context,
    'data': data,
  };

  /// The payload as a JSON string.
  String encode() => jsonEncode(toJson());
}

/// A reserved job handed to the worker.
/// A claimed row whose payload is Daravel-shaped but does not decode. The
/// driver has removed the row; [raw] is what it held, for `failed_jobs`.
final class CorruptPayloadException extends DaravelException {
  /// A job row whose payload cannot be read.
  CorruptPayloadException({
    required this.id,
    required this.queue,
    required this.raw,
    required this.cause,
  }) : super(
         'Job $id on queue [$queue] has a payload that does not decode: $cause',
       );

  /// The job's id in its queue.
  final Object id;

  /// The queue it was read from.
  final String queue;

  /// The payload text as stored.
  final String raw;

  /// The parse error.
  final Object cause;
}

/// A job reserved from a queue, being processed.
final class QueuedJob {
  /// The reserved job [id] of [queue] carrying [payload].
  const QueuedJob({
    required this.id,
    required this.queue,
    required this.payload,
    required this.attempts,
    required this.raw,
    this.reservedUntil,
  });

  /// The job's id in its queue.
  final Object id;

  /// The queue it was reserved from.
  final String queue;

  /// The decoded payload.
  final JobPayload payload;

  /// Attempts including the current one.
  final int attempts;

  /// Stored JSON (for `failed_jobs`).
  final String raw;

  /// For a [ReservingQueueDriver]: the driver never hands this job to
  /// another worker before this moment, on the clock of the process that
  /// pops next (the reservation as the driver stored it, which may be
  /// coarser than [ReservingQueueDriver.retryAfter] suggests: the database
  /// queue counts whole seconds). `null` when the driver does not say.
  ///
  /// It is the reservation taken by the pop; a later
  /// [ReservingQueueDriver.touch] extends the stored reservation but not
  /// this value.
  final DateTime? reservedUntil;
}

/// Queue backend (BLUEPRINT_V2 §7.9.1).
abstract interface class QueueDriver {
  /// The connection's name.
  String get name;

  /// Where the jobs live: one isolate, the process, or the cluster.
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

  /// Removes [job] from the queue for good.
  Future<void> delete(QueuedJob job);

  /// The number of jobs waiting on [queue].
  Future<int> size(String queue);

  /// How long the oldest job that is ready to run on [queue] has been
  /// waiting (`null` when none is waiting). Used by queue dashboards and
  /// auto-scaling (Laravel Horizon's "wait time").
  Future<Duration?> oldestWait(String queue);

  /// Removes every job of [queue] and returns how many there were.
  Future<int> clear(String queue);
}

/// A driver that wakes an idle worker as soon as a job is pushed, instead
/// of the worker sleeping `--sleep` between empty polls.
abstract interface class WakeableQueueDriver implements QueueDriver {
  /// Completes when a job may be ready on one of [queues], or after
  /// [maxWait] at the latest.
  Future<void> waitForWork(List<String> queues, Duration maxWait);

  /// Releases what [waitForWork] holds (a listening connection) once the
  /// worker stops.
  Future<void> stopWaiting();
}

/// A driver that reserves a popped job for [retryAfter] (`retry_after`)
/// and hands it to another worker once that passes, taking it for
/// abandoned: the database and Redis queues.
///
/// The worker [touch]es the reservation of a running job every half
/// [retryAfter], so a job that runs longer than [retryAfter] is not run a
/// second time beside itself.
abstract interface class ReservingQueueDriver implements QueueDriver {
  /// How long a reservation lasts before the job runs again elsewhere.
  Duration get retryAfter;

  /// Extends [job]'s reservation to [retryAfter] from now; does nothing
  /// once the job is gone or reserved again by another worker.
  Future<void> touch(QueuedJob job);
}

/// A job waiting in a queue, as a dashboard lists it
/// ([BrowsableQueueDriver]). Reading it reserves nothing.
///
/// The fields come from the stored payload, read leniently: a job pushed by
/// a Laravel app sharing the queue is listed too, with its PHP handler as
/// [jobName].
final class QueuedJobView {
  /// A waiting job [id] of [queue].
  const QueuedJobView({
    required this.id,
    required this.uuid,
    required this.jobName,
    required this.displayName,
    required this.queue,
    required this.tags,
    required this.pushedAt,
    required this.availableAt,
    required this.attempts,
    required this.payload,
  });

  /// The view of the stored [payload] JSON of job [id] on [queue].
  factory QueuedJobView.fromStored({
    required Object id,
    required String queue,
    required String payload,
    required int attempts,
    required DateTime availableAt,
  }) {
    Object? decoded;
    try {
      decoded = jsonDecode(payload);
    } on FormatException {
      decoded = null;
    }
    final json = decoded is Map<String, Object?>
        ? decoded
        : const <String, Object?>{};
    final job = json['job'];
    final jobName = job is String ? job : '';
    final display = json['displayName'];
    final pushed = json['pushedAt'];
    return QueuedJobView(
      id: id,
      uuid: json['uuid'] is String ? json['uuid']! as String : '',
      jobName: jobName,
      displayName: display is String ? display : jobName,
      queue: queue,
      tags: [
        for (final tag
            in json['tags'] is List<Object?>
                ? json['tags']! as List<Object?>
                : const <Object?>[])
          if (tag is String) tag,
      ],
      pushedAt: pushed is num && pushed > 0
          ? DateTime.fromMillisecondsSinceEpoch(
              pushed.toInt() * 1000,
              isUtc: true,
            )
          : null,
      availableAt: availableAt,
      attempts: attempts,
      payload: payload,
    );
  }

  /// The job's id in its queue (what [ReclaimableQueueDriver.reclaim]
  /// takes).
  final Object id;

  /// The dispatch's UUID (empty when the payload has none).
  final String uuid;

  /// The registered job name.
  final String jobName;

  /// The name shown in dashboards.
  final String displayName;

  /// The queue it waits on.
  final String queue;

  /// Its monitoring tags ([Job.tags]).
  final List<String> tags;

  /// When it was first pushed (UTC), when the payload says.
  final DateTime? pushedAt;

  /// When it may run (UTC); later than now for a delayed job.
  final DateTime availableAt;

  /// How many times it was reserved so far.
  final int attempts;

  /// The stored payload JSON, unchanged.
  final String payload;

  /// The view as JSON, for dashboards.
  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'uuid': uuid,
    'name': jobName,
    'displayName': displayName,
    'queue': queue,
    'tags': tags,
    'pushedAt': pushedAt?.toIso8601String(),
    'availableAt': availableAt.toIso8601String(),
    'attempts': attempts,
    'payload': payload,
  };
}

/// A driver whose waiting jobs can be listed without reserving them, for
/// queue dashboards (`daravel_horizon`'s pending and delayed lists).
abstract interface class BrowsableQueueDriver implements QueueDriver {
  /// Jobs of [queue] ready to run, in the order they would be popped,
  /// skipping [offset] and returning at most [limit].
  Future<List<QueuedJobView>> pending(
    String queue, {
    int limit = 50,
    int offset = 0,
  });

  /// Jobs of [queue] waiting for their delay, soonest first.
  Future<List<QueuedJobView>> delayed(
    String queue, {
    int limit = 50,
    int offset = 0,
  });
}

/// A driver that can hand a reserved job back at once, without waiting
/// for `retry_after`: for a supervisor that knows the job's worker is gone
/// (`daravel_horizon` after a worker isolate stops answering). The job's
/// attempts are kept, so `tries` still counts the lost attempt.
///
/// Only for a job whose worker is gone: a worker still running it would
/// run it a second time beside the next one.
abstract interface class ReclaimableQueueDriver implements QueueDriver {
  /// Makes the reserved job [jobId] of [queue] available again; returns
  /// whether it was reserved (false when it finished or was never there).
  Future<bool> reclaim(String queue, Object jobId);
}

/// Clamps a page request to sane values.
(int, int) _page(int limit, int offset) =>
    (limit < 0 ? 0 : limit, offset < 0 ? 0 : offset);

/// Completes the first of [wake] and [maxWait].
Future<void> _within(Future<void> wake, Duration maxWait) {
  final done = Completer<void>();
  final timer = Timer(maxWait, () {
    if (!done.isCompleted) {
      done.complete();
    }
  });
  unawaited(
    wake.then((_) {
      timer.cancel();
      if (!done.isCompleted) {
        done.complete();
      }
    }),
  );
  return done.future;
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

/// In-memory queue (scope `isolate`): tests, and a worker in the isolate
/// that dispatches (`QueueWorker` run beside the code that pushes). Every
/// isolate has its own, so `serve` refuses it with several isolates or
/// `--embed-queue`, whose worker runs in an isolate of its own.
final class MemoryQueue
    implements
        WakeableQueueDriver,
        BrowsableQueueDriver,
        ReclaimableQueueDriver {
  /// A queue in this isolate's memory; [clock] is for tests.
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
    _wake(queue);
    return id;
  }

  final Map<String, List<Completer<void>>> _waiting = {};

  void _wake(String queue) {
    for (final waiter in _waiting.remove(queue) ?? const <Completer<void>>[]) {
      if (!waiter.isCompleted) {
        waiter.complete();
      }
    }
  }

  @override
  Future<void> waitForWork(List<String> queues, Duration maxWait) {
    final waiter = Completer<void>();
    for (final queue in queues) {
      (_waiting[queue] ??= []).add(waiter);
    }
    return _within(waiter.future, maxWait).whenComplete(() {
      for (final queue in queues) {
        _waiting[queue]?.remove(waiter);
      }
    });
  }

  @override
  Future<void> stopWaiting() async {}

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

  @override
  Future<List<QueuedJobView>> pending(
    String queue, {
    int limit = 50,
    int offset = 0,
  }) async {
    final now = _now;
    // pop takes the first match in insertion order.
    return _views(
      _entries.where(
        (e) => e.queue == queue && !e.reserved && e.availableAt <= now,
      ),
      limit,
      offset,
    );
  }

  @override
  Future<List<QueuedJobView>> delayed(
    String queue, {
    int limit = 50,
    int offset = 0,
  }) async {
    final now = _now;
    final waiting = [
      for (final e in _entries)
        if (e.queue == queue && !e.reserved && e.availableAt > now) e,
    ]..sort((a, b) => a.availableAt.compareTo(b.availableAt));
    return _views(waiting, limit, offset);
  }

  List<QueuedJobView> _views(
    Iterable<_MemoryEntry> entries,
    int limit,
    int offset,
  ) {
    final (take, skip) = _page(limit, offset);
    return [
      for (final e in entries.skip(skip).take(take))
        QueuedJobView.fromStored(
          id: e.id,
          queue: e.queue,
          payload: e.payload.encode(),
          attempts: e.attempts,
          availableAt: DateTime.fromMillisecondsSinceEpoch(
            e.availableAt,
            isUtc: true,
          ),
        ),
    ];
  }

  @override
  Future<bool> reclaim(String queue, Object jobId) async {
    for (final entry in _entries) {
      if (entry.id == jobId && entry.queue == queue && entry.reserved) {
        entry.reserved = false;
        _wake(queue);
        return true;
      }
    }
    return false;
  }

  static DateTime _utcNow() => Clock.now().toUtc();
}

/// Laravel-compatible `jobs` table (scope `cluster`). Reservation is an
/// optimistic `UPDATE … WHERE reserved_at IS NULL`, so several workers
/// never process the same row twice.
final class DatabaseQueue
    implements
        WakeableQueueDriver,
        ReservingQueueDriver,
        BrowsableQueueDriver,
        ReclaimableQueueDriver {
  /// A queue in the [table] (`jobs`) of [db], shared with Laravel's
  /// database queue.
  DatabaseQueue(
    this.db, {
    this.table = 'jobs',
    this.connection,
    this.retryAfter = const Duration(seconds: 90),
    this.onForeignJob,
    this.listenRetry = const Duration(seconds: 30),
    DateTime Function()? clock,
  }) : _clock = clock ?? _utcNow;

  /// The database holding the jobs.
  final DatabaseManager db;

  /// The jobs table.
  final String table;

  /// The connection of the table; the default one when null.
  final String? connection;

  /// Reserved jobs older than this are considered abandoned and re-queued.
  @override
  final Duration retryAfter;

  /// How long after a `LISTEN` that failed or dropped (PostgreSQL) the
  /// next wait listens again.
  final Duration listenRetry;

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
    // Wakes idle workers on every machine (PostgreSQL; sent at commit when
    // pushed inside a transaction). Delayed jobs wait for their time.
    if (delay == null || delay <= Duration.zero) {
      await db.notify(_channel, queue, connection);
    }
    return id!;
  }

  /// The notification channel of this jobs table.
  String get _channel => 'daravel_queue_$table';

  StreamSubscription<String>? _notifications;
  final Map<String, List<Completer<void>>> _waiting = {};

  /// False once the database answered that it has no notifications.
  bool _notifiable = true;

  /// The subscription being opened, shared by concurrent waits.
  Future<void>? _subscribing;

  /// No `LISTEN` before this (wall clock): set after one failed or dropped.
  DateTime? _listenAfter;

  /// Waits for a `NOTIFY` from a push on PostgreSQL, through one connection
  /// kept until [stopWaiting]; other databases sleep [maxWait], as before.
  /// A `LISTEN` that cannot be opened (the database is down) or that drops
  /// is tried again after [listenRetry]; meanwhile the wait is a sleep.
  @override
  Future<void> waitForWork(List<String> queues, Duration maxWait) async {
    await (_subscribing ??= _subscribe().whenComplete(
      () => _subscribing = null,
    ));
    if (_notifications == null) {
      return Future<void>.delayed(maxWait);
    }
    final waiter = Completer<void>();
    for (final queue in queues) {
      (_waiting[queue] ??= []).add(waiter);
    }
    await _within(waiter.future, maxWait);
    for (final queue in queues) {
      _waiting[queue]?.remove(waiter);
    }
  }

  Future<void> _subscribe() async {
    final after = _listenAfter;
    if (_notifications != null ||
        !_notifiable ||
        (after != null && DateTime.now().isBefore(after))) {
      return;
    }
    final Stream<String>? stream;
    try {
      stream = await db.notifications(_channel, connection: connection);
    } on Object {
      _listenAfter = DateTime.now().add(listenRetry);
      return;
    }
    if (stream == null) {
      _notifiable = false;
      return;
    }
    _listenAfter = null;
    _notifications = stream.listen(
      (queue) {
        for (final waiter
            in _waiting.remove(queue) ?? const <Completer<void>>[]) {
          if (!waiter.isCompleted) {
            waiter.complete();
          }
        }
      },
      // A dropped connection: sleep and poll, and listen again later.
      onError: (Object _) => unawaited(_dropNotifications(retry: true)),
      onDone: () => unawaited(_dropNotifications(retry: true)),
    );
  }

  Future<void> _dropNotifications({bool retry = false}) async {
    if (retry) {
      _listenAfter = DateTime.now().add(listenRetry);
    }
    final cancelled = _notifications?.cancel();
    _notifications = null;
    await cancelled;
  }

  @override
  Future<void> stopWaiting() async {
    _listenAfter = null;
    _notifiable = true;
    await _dropNotifications();
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
        final JobPayload payload;
        try {
          payload = JobPayload.decode(raw);
        } on Object catch (error) {
          // A Daravel-shaped row that does not decode (a field of the wrong
          // type, a payload written by another release): the row is claimed
          // and would otherwise be re-reserved after retry_after and crash
          // the next worker too, for ever. It is removed here; the worker
          // records it in failed_jobs from the exception.
          await _query().where('id', id).delete();
          throw CorruptPayloadException(
            id: id,
            queue: queue,
            raw: raw,
            cause: error,
          );
        }
        return QueuedJob(
          id: id,
          queue: queue,
          payload: payload,
          attempts: (row['attempts'] as num).toInt() + 1,
          raw: raw,
          reservedUntil: _reservedUntil(now),
        );
      }
    }
    return null;
  }

  /// When a job reserved at [reservedAt] (`reserved_at`, whole seconds)
  /// can first be popped again.
  ///
  /// With r = [reservedAt] and R = `retryAfter.inSeconds` (whole seconds:
  /// a `retry_after` of 2.5 s counts as 2), [pop] at m milliseconds takes
  /// the job iff r <= floor(m / 1000) - R, that is floor(m / 1000) >= r + R,
  /// that is m >= 1000 * (r + R) (floor(x) >= k iff x >= k for a whole k).
  /// So the job is never handed out before 1000 * (r + R) ms and may be at
  /// that moment: between R - 1 and R seconds after the pop that reserved
  /// it, depending on where in its second the pop fell.
  DateTime _reservedUntil(int reservedAt) =>
      DateTime.fromMillisecondsSinceEpoch(
        (reservedAt + retryAfter.inSeconds) * 1000,
        isUtc: true,
      );

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

  /// Moves `reserved_at` to now while the row is still this reservation:
  /// `attempts` grows with every reservation, so a row another worker took
  /// meanwhile is left alone.
  @override
  Future<void> touch(QueuedJob job) async {
    await _query()
        .where('id', job.id)
        .where('attempts', job.attempts)
        .whereNotNull('reserved_at')
        .update(<String, Object?>{'reserved_at': _now});
  }

  @override
  Future<void> release(QueuedJob job, Duration delay) =>
      _whileReserved(() async {
        await _query().where('id', job.id).update(<String, Object?>{
          'reserved_at': null,
          'available_at': _now + delay.inSeconds,
        });
      });

  @override
  Future<void> delete(QueuedJob job) => _whileReserved(() async {
    await _query().where('id', job.id).delete();
  });

  /// Runs [body] (the delete or release of a job this worker ran) again
  /// after a transient error (a deadlock, SQLite busy or locked), for at
  /// most half of [retryAfter] counted from the first attempt of [body].
  /// Before, one such error after the job ran left its row reserved, and the
  /// job ran a second time once [retryAfter] passed: a "completed 301 of
  /// 300" with no worker killed (Horizon `master_test` on Windows, SQLite
  /// busy on the DELETE).
  ///
  /// The bound counts from here, not from the reservation (a [QueuedJob]
  /// does not carry its reservation time, and a running job's heartbeat
  /// moves it): a job that ran for most of [retryAfter] may be retried past
  /// its reservation, when another worker may already have reserved it
  /// again. That job then runs again, as it would have without the retry;
  /// beyond the bound it may run again too. Both are the queue's
  /// at-least-once guarantee, as in Laravel: jobs must be idempotent.
  Future<void> _whileReserved(Future<void> Function() body) async {
    final watch = Stopwatch()..start();
    final limit = retryAfter ~/ 2;
    var wait = DatabaseManager.retryBaseDelay;
    while (true) {
      try {
        await body();
        return;
      } on Object catch (error) {
        if (watch.elapsed + wait >= limit ||
            !await db.isRetryable(error, connection: connection)) {
          rethrow;
        }
      }
      await Future<void>.delayed(wait);
      wait = DatabaseManager.retryDelay(wait, _retryRandom);
    }
  }

  static final math.Random _retryRandom = math.Random();

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

  /// Unreserved rows whose `available_at` has come, by `available_at` and
  /// then `id`. Rows pushed by Laravel are listed as well.
  @override
  Future<List<QueuedJobView>> pending(
    String queue, {
    int limit = 50,
    int offset = 0,
  }) => _browse(queue, limit, offset, due: true);

  /// Unreserved rows whose `available_at` is still ahead, soonest first.
  @override
  Future<List<QueuedJobView>> delayed(
    String queue, {
    int limit = 50,
    int offset = 0,
  }) => _browse(queue, limit, offset, due: false);

  Future<List<QueuedJobView>> _browse(
    String queue,
    int limit,
    int offset, {
    required bool due,
  }) async {
    final (take, skip) = _page(limit, offset);
    if (take == 0) {
      return const [];
    }
    final rows = await _query()
        .where('queue', queue)
        .whereNull('reserved_at')
        .where('available_at', due ? '<=' : '>', _now)
        .orderBy('available_at')
        .orderBy('id')
        .offset(skip)
        .limit(take)
        .get();
    return [
      for (final row in rows)
        QueuedJobView.fromStored(
          id: row['id']!,
          queue: queue,
          payload: row['payload']! as String,
          attempts: (row['attempts'] as num).toInt(),
          availableAt: DateTime.fromMillisecondsSinceEpoch(
            (row['available_at']! as num).toInt() * 1000,
            isUtc: true,
          ),
        ),
    ];
  }

  /// Clears `reserved_at` of the row; `attempts` and `available_at` stay.
  @override
  Future<bool> reclaim(String queue, Object jobId) async {
    final reclaimed = await _query()
        .where('id', jobId)
        .where('queue', queue)
        .whereNotNull('reserved_at')
        .update(<String, Object?>{'reserved_at': null});
    if (reclaimed > 0) {
      await db.notify(_channel, queue, connection);
    }
    return reclaimed > 0;
  }

  static DateTime _utcNow() => Clock.now().toUtc();
}

/// Runs jobs inline at push time (dev/test). [processor] is wired by the
/// queue manager.
final class SyncQueue implements QueueDriver {
  /// A queue that runs each job as soon as it is pushed.
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
  /// A failed job, as stored in `failed_jobs`.
  const FailedJob({
    required this.id,
    required this.uuid,
    required this.connection,
    required this.queue,
    required this.payload,
    required this.exception,
    required this.failedAt,
  });

  /// The row id.
  final Object id;

  /// The job's UUID, used by `queue:retry`.
  final String uuid;

  /// The queue connection it ran on.
  final String connection;

  /// The queue it ran on.
  final String queue;

  /// The payload JSON, to retry it.
  final String payload;

  /// The exception and its trace.
  final String exception;

  /// When it failed.
  final DateTime failedAt;

  /// The failed job as JSON.
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
  /// Records a failed job and returns its id.
  Future<Object> log({
    required String connection,
    required String queue,
    required String payload,
    required String exception,
  });

  /// Every failed job, newest first.
  Future<List<FailedJob>> all();

  /// The failed job [id] (a row id or UUID), or null.
  Future<FailedJob?> find(Object id);

  /// Deletes the failed job [id]; returns whether it existed.
  Future<bool> forget(Object id);

  /// Deletes every failed job and returns how many there were.
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
  /// Failed jobs in the [table] (`failed_jobs`) of [db].
  DatabaseFailedJobProvider(
    this.db, {
    this.table = 'failed_jobs',
    this.connection,
  });

  /// The database holding the failed jobs.
  final DatabaseManager db;

  /// The failed jobs table.
  final String table;

  /// The connection of the table; the default one when null.
  final String? connection;

  QueryBuilder _query() => db.table(table, connection: connection);

  @override
  Future<Object> log({
    required String connection,
    required String queue,
    required String payload,
    required String exception,
  }) async {
    // The payload may be the one that could not be decoded (the reason
    // it failed): its uuid is read leniently, or made up.
    String uuid;
    try {
      uuid = JobPayload.decode(payload).uuid;
    } on Object {
      final loose = jsonDecode(payload);
      uuid = loose is Map && loose['uuid'] is String
          ? loose['uuid'] as String
          : const Uuid().v4();
    }
    final id = await _query().insertGetId(<String, Object?>{
      'uuid': uuid,
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

  // Text without a zone (MySQL's `Y-m-d H:i:s`) is UTC, as written.
  static DateTime? _parse(Object? value) => switch (value) {
    DateTime() => value.toUtc(),
    _ => parseDateTime(value)?.toUtc(),
  };
}

/// Creates `jobs`, `job_batches` and `failed_jobs` with Laravel 11's schema
/// and migration name.
final class CreateJobsTable extends Migration {
  /// The migration creating `jobs` and `failed_jobs`, as Laravel's.
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
