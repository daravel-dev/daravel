import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import '../foundation/clock.dart';

import 'package:uuid/uuid.dart';

import '../database/database_manager.dart';
import '../database/orm/casts.dart';
import '../foundation/exceptions.dart';
import '../logging/context.dart';
import '../logging/logger.dart';
import '../database/query/query_builder.dart';
import '../database/query_executor.dart';
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
    this.attemptsExhausted = false,
  });

  /// Whether the driver cannot count another attempt: the database queue's
  /// `attempts` column stops at 255 (Laravel's `TINYINT UNSIGNED`). The
  /// worker fails such a job with [MaxAttemptsExceededException] without
  /// running it, also when its `tries` is 0 (unlimited).
  final bool attemptsExhausted;

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
  /// this value ([ExtendingQueueDriver.extend] returns the new end).
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

/// A [ReservingQueueDriver] that says how far it extended a reservation,
/// so a supervisor watching a running job (`daravel_horizon`) can follow
/// it: the database and Redis queues.
abstract interface class ExtendingQueueDriver implements ReservingQueueDriver {
  /// Extends [job]'s reservation as [touch] does and returns until when the
  /// driver now keeps it from other workers, with the guarantee of
  /// [QueuedJob.reservedUntil]; null when nothing changed: the reservation
  /// is no longer this job's (gone, or reserved again by another worker),
  /// or it already ends there (the end told before stands).
  Future<DateTime?> extend(QueuedJob job);
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

/// A queue that knows which reservation of a job is current: `attempts`
/// grows with every reservation, so a worker that ran past `retry_after`
/// (and lost its job to another worker) can tell. The worker asks before
/// it records the job as failed, so a job another worker still runs is
/// never recorded, hooked (`failed()`) or announced (`JobFailed`) by the
/// worker that lost it.
abstract interface class OwnershipQueueDriver implements QueueDriver {
  /// Whether [job] is still the current reservation (no other worker
  /// reserved it since).
  Future<bool> owns(QueuedJob job);

  /// [QueueDriver.delete], answering whether it removed the job: false when
  /// another worker reserved it since (and nothing was removed).
  Future<bool> deleteOwned(QueuedJob job);
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
        ExtendingQueueDriver,
        BrowsableQueueDriver,
        ReclaimableQueueDriver,
        OwnershipQueueDriver {
  /// A queue in the [table] (`jobs`) of [db], shared with Laravel's
  /// database queue.
  DatabaseQueue(
    this.db, {
    this.table = 'jobs',
    this.connection,
    this.retryAfter = const Duration(seconds: 90),
    this.onForeignJob,
    this.listenRetry = const Duration(seconds: 30),
    this.isKnownJob,
    this.logger,
    DateTime Function()? clock,
  }) : _clock = clock ?? _utcNow;

  /// Whether a job name is registered in this application (the job
  /// registry's `has`): a registered name is always a Daravel job, whatever
  /// its `data` holds ([isForeignPayload]).
  final bool Function(String jobName)? isKnownJob;

  /// Told once per job when a worker that ran past `retry_after` finds its
  /// job taken by another worker ([delete], [release]), and of a row that
  /// cannot be claimed ([pop]).
  final Logger? logger;

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

  /// Per queue: every row this worker could take with an id up to the
  /// cursor's was foreign when it last looked, so [pop] reads past them
  /// without fetching them again ([_Cursor]).
  final Map<String, _Cursor> _cursors = <String, _Cursor>{};

  /// Per queue, the highest foreign id reported through [onForeignJob]:
  /// ids grow, so a row read again after a cursor reset is not reported
  /// twice. Ids that are not integers are remembered in
  /// [_reportedForeign] (bounded, oldest first).
  final Map<String, int> _reportedThrough = <String, int>{};
  final Set<Object> _reportedForeign = <Object>{};
  static const int _maxReportedForeign = 1000;

  /// Rows read by the first query of a poll; doubled (four times) after
  /// each batch that held only foreign rows, up to [_maxPollBatch].
  static const int _pollBatch = 16;
  static const int _maxPollBatch = 1000;

  /// Selects per [pop] while looking past foreign rows.
  static const int _maxPolls = 8;

  /// Slack for clocks of other processes that write `available_at` and
  /// `reserved_at` ([_Cursor.since]).
  static const int _clockSlack = 5;

  /// `attempts` is a `TINYINT UNSIGNED` in Laravel's `jobs` table (MySQL
  /// refuses 256); a row that reached it is failed, not reserved again.
  /// There `attempts` no longer grows, so it no longer tells two
  /// reservations of that row apart as the ownership token; the row is
  /// failed on its next reservation anyway.
  static const int _maxAttempts = 255;

  /// Whether [raw] was pushed by Laravel rather than Daravel.
  ///
  /// Not a JSON object, a `job` that is not a string, or one with a `\` or
  /// `@` (a PHP handler such as `Illuminate\Queue\CallQueuedHandler@call`;
  /// Daravel job names never hold either) is foreign. A `job` that
  /// [isKnownJob] knows is Daravel's whatever its `data` holds. Otherwise a
  /// `data` with `commandName`, or a string `command` (Laravel's
  /// serialized command), is foreign: an unregistered Daravel job with a
  /// string `command` field is therefore skipped as foreign, never popped;
  /// register it to have it run. Any other row is Daravel's.
  static bool isForeignPayload(
    String raw, {
    bool Function(String jobName)? isKnownJob,
  }) {
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
    if (isKnownJob != null && isKnownJob(job)) {
      return false;
    }
    final data = decoded['data'];
    return data is Map<String, Object?> &&
        (data.containsKey('commandName') || data['command'] is String);
  }

  bool _isForeign(String raw) => isForeignPayload(raw, isKnownJob: isKnownJob);

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
  ///
  /// Foreign rows are read past with a cursor per queue: every row this
  /// worker could take up to the cursor was foreign when it looked. Rows
  /// below it that become available later (a delayed job falling due, a
  /// job released by any worker, a reservation that went stale) are found
  /// by a second, narrow query ([_Cursor]); the cursor starts over every
  /// `retryAfter` as a safety net. A queue without foreign rows never moves
  /// it.
  @override
  Future<QueuedJob?> pop(String queue) async {
    final now = _now;
    final stale = now - retryAfter.inSeconds;
    var cursor = _cursors[queue];
    if (cursor != null && now - cursor.since >= retryAfter.inSeconds) {
      _cursors.remove(queue);
      cursor = null;
    }
    if (cursor != null) {
      // Below the cursor: only what became available since it was set.
      final rows = await _available(queue, now, stale)
          .where('id', '<=', cursor.through)
          .where((QueryBuilder q) {
            q
                .where('available_at', '>', cursor!.since - _clockSlack)
                .whereNull('reserved_at', not: true, boolean: 'OR');
          })
          .orderBy('id')
          .limit(_maxPollBatch)
          .get();
      final (job, _) = await _claimFirst(queue, rows, now);
      if (job != null) {
        return job;
      }
    }
    var batch = _pollBatch;
    for (var poll = 0; poll < _maxPolls; poll++) {
      final after = _cursors[queue]?.through ?? 0;
      final rows = await _available(
        queue,
        now,
        stale,
      ).where('id', '>', after).orderBy('id').limit(batch).get();
      final (job, foreignThrough) = await _claimFirst(queue, rows, now);
      if (foreignThrough != null) {
        // Every row read up to it was foreign: the next poll starts past it.
        (_cursors[queue] ??= _Cursor(now)).through = foreignThrough;
      }
      if (job != null) {
        return job;
      }
      if (rows.length < batch) {
        return null;
      }
      if (foreignThrough == rows.last['id']) {
        batch = math.min(batch * 4, _maxPollBatch);
      }
    }
    return null;
  }

  /// The rows of [queue] a worker may take at [now]: waiting and due, or
  /// reserved before [stale].
  QueryBuilder _available(String queue, int now, int stale) =>
      _query().where('queue', queue).where((QueryBuilder q) {
        q
            .where((QueryBuilder available) {
              available
                  .whereNull('reserved_at')
                  .where('available_at', '<=', now);
            })
            .orWhere('reserved_at', '<=', stale);
      });

  /// Claims the first Daravel row of [rows] (in id order); returns it, and
  /// the id through which every row read was foreign (null when the first
  /// row was not).
  ///
  /// A row whose claim fails with an error is passed over (logged once), so
  /// one bad row does not hold the queue; a second failure in a row is not
  /// the row's and is thrown.
  Future<(QueuedJob?, Object?)> _claimFirst(
    String queue,
    List<Map<String, Object?>> rows,
    int now,
  ) async {
    Object? foreignThrough;
    var prefix = true;
    Object? failedBefore;
    for (final row in rows) {
      final id = row['id']!;
      final raw = row['payload']! as String;
      if (_isForeign(raw)) {
        _reportForeign(queue, id, raw);
        if (prefix) {
          foreignThrough = id;
        }
        continue;
      }
      prefix = false;
      final attempts = (row['attempts'] as num).toInt();
      final exhausted = attempts >= _maxAttempts;
      final previousReserved = row['reserved_at'];
      final int claimed;
      try {
        claimed = await _query()
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
              if (!exhausted) 'attempts': attempts + 1,
            });
      } on QueryException catch (error) {
        if (failedBefore != null) {
          rethrow;
        }
        failedBefore = error;
        _warnOnce(
          id,
          'Job $id on queue [$queue] cannot be reserved and was passed '
          'over: $error',
        );
        continue;
      }
      if (claimed != 1) {
        continue; // Another worker took it first.
      }
      final current = exhausted ? attempts : attempts + 1;
      final JobPayload payload;
      try {
        payload = JobPayload.decode(raw);
      } on Object catch (error) {
        // A Daravel-shaped row that does not decode (a field of the wrong
        // type, a payload written by another release): the row is claimed
        // and would otherwise be re-reserved after retry_after and crash
        // the next worker too, for ever. It is removed here; the worker
        // records it in failed_jobs from the exception.
        await _query().where('id', id).where('attempts', current).delete();
        throw CorruptPayloadException(
          id: id,
          queue: queue,
          raw: raw,
          cause: error,
        );
      }
      return (
        QueuedJob(
          id: id,
          queue: queue,
          payload: payload,
          attempts: current,
          raw: raw,
          reservedUntil: _reservedUntil(now),
          attemptsExhausted: exhausted,
        ),
        foreignThrough,
      );
    }
    return (null, foreignThrough);
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

  void _reportForeign(String queue, Object id, String raw) {
    if (id is int) {
      if (id <= (_reportedThrough[queue] ?? 0)) {
        return;
      }
      _reportedThrough[queue] = id;
    } else {
      if (!_reportedForeign.add(id)) {
        return;
      }
      if (_reportedForeign.length > _maxReportedForeign) {
        _reportedForeign.remove(_reportedForeign.first);
      }
    }
    String handler;
    try {
      final decoded = jsonDecode(raw);
      handler = decoded is Map<String, Object?> ? '${decoded['job']}' : '?';
    } on FormatException {
      handler = '?';
    }
    onForeignJob?.call(queue, id, handler);
  }

  /// Job ids already warned about ([_warnOnce]); bounded, oldest first.
  final Set<Object> _warned = <Object>{};

  void _warnOnce(Object id, String message) {
    if (!_warned.add(id)) {
      return;
    }
    if (_warned.length > _maxReportedForeign) {
      _warned.remove(_warned.first);
    }
    logger?.warning(message, <String, Object?>{'job_id': id});
  }

  /// The row of [job] while no other worker reserved it since: `attempts`
  /// grows with every reservation, so a row another worker reserved after
  /// this one ran past `retry_after` does not match. A waiting row whose
  /// `attempts` match (one `daravel_horizon` quarantines after a reclaim)
  /// does.
  QueryBuilder _unchanged(QueuedJob job) =>
      _query().where('id', job.id).where('attempts', job.attempts);

  /// [_unchanged], and still reserved: what a release puts back.
  QueryBuilder _owned(QueuedJob job) =>
      _unchanged(job).whereNotNull('reserved_at');

  void _notOwner(QueuedJob job, String action) => _warnOnce(
    job.id,
    'Job ${job.id} on queue [${job.queue}] ran past retry_after: another '
    'worker took it, so its $action did nothing. Raise retry_after above '
    'the longest job.',
  );

  /// Moves `reserved_at` to now while the row is still this reservation:
  /// `attempts` grows with every reservation, so a row another worker took
  /// meanwhile is left alone.
  @override
  Future<void> touch(QueuedJob job) => extend(job);

  /// [touch], and the new reservation's end: `reserved_at` becomes now in
  /// whole seconds, so the job is kept until exactly 1000 * (now + R) ms,
  /// as for a pop ([_reservedUntil]). Within the second it was reserved or
  /// last extended, MySQL counts the row as unchanged and this returns
  /// null: the reservation's end did not move.
  @override
  Future<DateTime?> extend(QueuedJob job) async {
    final now = _now;
    final updated = await _query()
        .where('id', job.id)
        .where('attempts', job.attempts)
        .whereNotNull('reserved_at')
        .update(<String, Object?>{'reserved_at': now});
    return updated == 1 ? _reservedUntil(now) : null;
  }

  /// Puts [job] back after [delay], while it is still this worker's
  /// reservation ([_owned]); otherwise it does nothing and warns once.
  /// Stricter than Laravel, whose `deleteAndRelease` checks only that the
  /// row exists.
  @override
  Future<void> release(QueuedJob job, Duration delay) =>
      _whileReserved(() async {
        final updated = await _owned(job).update(<String, Object?>{
          'reserved_at': null,
          'available_at': _now + delay.inSeconds,
        });
        if (updated == 0) {
          _notOwner(job, 'release');
        }
      });

  /// Removes [job] while no other worker reserved it since ([_unchanged]);
  /// otherwise it does nothing and warns once. Stricter than Laravel, whose
  /// `deleteReserved` checks only that the row exists.
  @override
  Future<void> delete(QueuedJob job) async {
    await deleteOwned(job);
  }

  @override
  Future<bool> deleteOwned(QueuedJob job) async {
    var removed = false;
    await _whileReserved(() async {
      removed = await _unchanged(job).delete() > 0;
    });
    if (!removed) {
      _notOwner(job, 'delete');
    }
    return removed;
  }

  @override
  Future<bool> owns(QueuedJob job) => _unchanged(job).exists();

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

/// The uuid a failed job is recorded with: the payload's own, or a new one
/// when the payload has none to give. The payload may be the very one that
/// could not be decoded (the reason the job failed): not JSON (`{{{`),
/// JSON that is not an object (`[1, 2, 3]`), empty, or an object without a
/// text `uuid`. Each is still recorded, never lost.
String _failedJobUuid(String payload) {
  try {
    if (jsonDecode(payload) case {'uuid': final String uuid}
        when uuid.isNotEmpty) {
      return uuid;
    }
  } on FormatException {
    // Not JSON: the reason it failed.
  }
  return const Uuid().v4();
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

/// A [FailedJobProvider] that reads its failed jobs a page at a time, by
/// their integer row ids, so retrying all of them (`queue:retry all`,
/// Horizon's retry-all) never holds every payload at once. Optional, as
/// Laravel's `ids()` is (`method_exists`): a provider without it is read
/// with [FailedJobProvider.all].
abstract interface class FailedJobPages {
  /// The largest id now (of [queue] when given), or null when none.
  Future<int?> lastId({String? queue});

  /// Up to [limit] failed jobs (of [queue] when given) whose id is above
  /// [after] and at most [upTo], by id.
  Future<List<FailedJob>> page({
    required int after,
    required int upTo,
    int limit = 500,
    String? queue,
  });

  /// How many failed jobs (of [queue] when given) have an id above [after]
  /// and at most [upTo].
  Future<int> countBetween({
    required int after,
    required int upTo,
    String? queue,
  });
}

/// In-memory failed job list (sync/memory connections, tests).
final class MemoryFailedJobProvider
    implements FailedJobProvider, FailedJobPages {
  final List<FailedJob> _jobs = <FailedJob>[];
  int _nextId = 0;

  Iterable<FailedJob> _between(int after, int upTo, String? queue) =>
      _jobs.where((job) {
        final id = job.id as int;
        return id > after &&
            id <= upTo &&
            (queue == null || job.queue == queue);
      });

  @override
  Future<int?> lastId({String? queue}) async {
    int? last;
    for (final job in _jobs) {
      if (queue == null || job.queue == queue) {
        last = job.id as int;
      }
    }
    return last;
  }

  @override
  Future<List<FailedJob>> page({
    required int after,
    required int upTo,
    int limit = 500,
    String? queue,
  }) async => _between(after, upTo, queue).take(limit).toList();

  @override
  Future<int> countBetween({
    required int after,
    required int upTo,
    String? queue,
  }) async => _between(after, upTo, queue).length;

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
        uuid: _failedJobUuid(payload),
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
final class DatabaseFailedJobProvider
    implements FailedJobProvider, FailedJobPages {
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
    final id = await _query().insertGetId(<String, Object?>{
      'uuid': _failedJobUuid(payload),
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

  QueryBuilder _between(int after, int upTo, String? queue) {
    final query = _query().where('id', '>', after).where('id', '<=', upTo);
    if (queue != null) {
      query.where('queue', queue);
    }
    return query;
  }

  @override
  Future<int?> lastId({String? queue}) async {
    final query = _query();
    if (queue != null) {
      query.where('queue', queue);
    }
    return switch (await query.max('id')) {
      null => null,
      final num id => id.toInt(),
      final Object id => int.parse('$id'),
    };
  }

  @override
  Future<List<FailedJob>> page({
    required int after,
    required int upTo,
    int limit = 500,
    String? queue,
  }) async => (await _between(
    after,
    upTo,
    queue,
  ).orderBy('id').limit(limit).get()).map(_fromRow).toList();

  @override
  Future<int> countBetween({
    required int after,
    required int upTo,
    String? queue,
  }) => _between(after, upTo, queue).count();

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

/// Where [DatabaseQueue.pop] resumes on a queue with foreign rows: every
/// row a worker could take with an id up to [through] was foreign when it
/// last looked. A row below it becomes available later only by a delayed
/// `available_at` falling due, a release (which sets `available_at` to the
/// time of the release or later) or a reservation going stale, so a narrow
/// query for `available_at` after [since] (less a slack for other
/// processes' clocks) or a stale `reserved_at` finds it. Pushes always get
/// ids above [through].
final class _Cursor {
  _Cursor(this.since);

  /// When the cursor was first set (seconds, the queue's clock).
  final int since;

  /// The id through which the rows read were foreign.
  Object through = 0;
}
