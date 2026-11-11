import 'dart:convert';

import 'package:daravel/daravel.dart';

/// One job as Horizon records it.
final class RecordedJob {
  /// A job [uuid] named [name] on [queue], [status] at [at] (epoch ms).
  const RecordedJob({
    required this.uuid,
    required this.name,
    required this.queue,
    required this.status,
    required this.at,
    this.tags = const [],
    this.durationMs,
    this.worker,
    this.error,
  });

  /// From [toJson].
  factory RecordedJob.fromJson(Map<String, Object?> json) => RecordedJob(
    uuid: json['uuid']! as String,
    name: json['name']! as String,
    queue: json['queue']! as String,
    status: json['status']! as String,
    at: (json['at']! as num).toInt(),
    tags: [for (final t in (json['tags'] as List<Object?>?) ?? const []) '$t'],
    durationMs: (json['duration_ms'] as num?)?.toInt(),
    worker: json['worker'] as String?,
    error: json['error'] as String?,
  );

  /// The dispatch's UUID.
  final String uuid;

  /// The job name.
  final String name;

  /// Its queue.
  final String queue;

  /// `completed` or `failed`.
  final String status;

  /// When it ended (epoch milliseconds).
  final int at;

  /// Its tags.
  final List<String> tags;

  /// How long it ran.
  final int? durationMs;

  /// The worker that ran it.
  final String? worker;

  /// The first line of its error, for a failed job.
  final String? error;

  /// The record as JSON.
  Map<String, Object?> toJson() => <String, Object?>{
    'uuid': uuid,
    'name': name,
    'queue': queue,
    'status': status,
    'at': at,
    'tags': tags,
    'duration_ms': ?durationMs,
    'worker': ?worker,
    'error': ?error,
  };
}

/// Horizon's `process` store (Blueprint #134 §3.6): recent completed and
/// failed jobs, and per-queue rates, in the coordinator, so every worker
/// isolate and the dashboard share them. Records and answers travel as JSON
/// strings (shared, not copied, between isolates).
///
/// Ops: `record` (`job`: a [RecordedJob] as JSON), `recent` (`status`,
/// `limit`) and `rates` (`queue`) → JSON.
///
/// When the coordinator falls behind, `record` is
/// [CoordinatorPriority.bulk] (a job missing from the dashboard's recent
/// list is harmless) and the reads are [CoordinatorPriority.normal].
final class HorizonService
    with PrioritizedService
    implements CoordinatorService, WorkerAwareService {
  /// A store keeping at most [maxPerStatus] jobs of each status, for
  /// [retention] (completed) and [failedRetention] (failed).
  HorizonService({
    this.maxPerStatus = 1000,
    this.retention = const Duration(minutes: 60),
    this.failedRetention = const Duration(days: 7),
    DateTime Function()? clock,
  }) : _clock = clock ?? Clock.now;

  /// The coordinator service name.
  static const String serviceName = 'horizon';

  /// The most jobs kept per status.
  final int maxPerStatus;

  /// How long completed jobs are kept.
  final Duration retention;

  /// How long failed jobs are kept.
  final Duration failedRetention;

  final DateTime Function() _clock;
  final Map<String, List<RecordedJob>> _jobs = {
    'completed': [],
    'failed': [],
    'silenced': [],
  };

  /// Tags whose jobs are kept apart, with the failed retention.
  final Set<String> _monitored = {};

  /// Jobs carrying a monitored tag.
  final List<RecordedJob> _tagged = [];

  /// The metric snapshots kept per job name and per queue.
  static const int maxSnapshots = 24;

  final Map<String, List<Map<String, Object?>>> _jobSnapshots = {};
  final Map<String, List<Map<String, Object?>>> _queueSnapshots = {};
  int? _lastSnapshotAt;

  @override
  String get name => serviceName;

  int get _now => _clock().millisecondsSinceEpoch;

  @override
  CoordinatorPriority get priority => CoordinatorPriority.normal;

  @override
  Set<String> get bulkOperations => const {'record'};

  @override
  Object? handle(String op, Map<String, Object?> args) {
    switch (op) {
      case 'record':
        final job = RecordedJob.fromJson(
          jsonDecode(args['job']! as String) as Map<String, Object?>,
        );
        final list = _jobs.putIfAbsent(job.status, () => [])..add(job);
        _trim(job.status, list);
        if (job.tags.any(_monitored.contains)) {
          _tagged.add(job);
          _trimTo(_tagged, failedRetention);
        }
        return null;
      case 'recent':
        final list = _jobs[args['status']! as String] ?? const [];
        final limit = (args['limit'] as num?)?.toInt() ?? 50;
        final offset = (args['offset'] as num?)?.toInt() ?? 0;
        return jsonEncode([
          for (final job in list.reversed.skip(offset).take(limit))
            job.toJson(),
        ]);
      case 'rates':
        return jsonEncode(rates(args['queue']! as String));
      case 'job':
        final found = job(args['uuid']! as String);
        return found == null ? null : jsonEncode(found.toJson());
      case 'monitor':
        _monitored.add(args['tag']! as String);
        return null;
      case 'unmonitor':
        _monitored.remove(args['tag']! as String);
        _tagged.removeWhere((job) => !job.tags.any(_monitored.contains));
        return null;
      case 'monitored':
        return jsonEncode([
          for (final tag in _monitored)
            {
              'tag': tag,
              'count': _tagged.where((job) => job.tags.contains(tag)).length,
            },
        ]);
      case 'tagged':
        final tag = args['tag']! as String;
        final limit = (args['limit'] as num?)?.toInt() ?? 50;
        return jsonEncode([
          for (final job
              in _tagged.reversed
                  .where((job) => job.tags.contains(tag))
                  .take(limit))
            job.toJson(),
        ]);
      case 'snapshot':
        snapshot();
        return null;
      case 'metrics':
        return jsonEncode({'jobs': _jobSnapshots, 'queues': _queueSnapshots});
      case 'summary':
        return jsonEncode(summary());
    }
    throw CoordinatorException('Unknown horizon operation [$op].');
  }

  /// Jobs of [queue] finished in the last minute: `per_second` and the
  /// average run time `avg_ms` (null without one).
  Map<String, Object?> rates(String queue) {
    final since = _now - 60000;
    var count = 0;
    var total = 0;
    var timed = 0;
    for (final status in const ['completed', 'failed', 'silenced']) {
      for (final job in _jobs[status] ?? const <RecordedJob>[]) {
        if (job.queue == queue && job.at >= since) {
          count++;
          final ms = job.durationMs;
          if (ms != null) {
            total += ms;
            timed++;
          }
        }
      }
    }
    return {
      'per_second': count / 60,
      'avg_ms': timed == 0 ? null : total / timed,
    };
  }

  void _trim(String status, List<RecordedJob> list) =>
      _trimTo(list, status == 'failed' ? failedRetention : retention);

  void _trimTo(List<RecordedJob> list, Duration keep) {
    final cutoff = _now - keep.inMilliseconds;
    list.removeWhere((job) => job.at < cutoff);
    if (list.length > maxPerStatus) {
      list.removeRange(0, list.length - maxPerStatus);
    }
  }

  /// The recorded job [uuid] (completed, failed or silenced), or null.
  RecordedJob? job(String uuid) {
    for (final list in _jobs.values) {
      for (final job in list.reversed) {
        if (job.uuid == uuid) {
          return job;
        }
      }
    }
    return null;
  }

  /// `jobs_per_minute` (finished in the last minute), `jobs_past_hour`
  /// and `failed_past_week`.
  Map<String, Object?> summary() {
    final now = _now;
    int within(Iterable<RecordedJob> jobs, Duration window) =>
        jobs.where((job) => job.at >= now - window.inMilliseconds).length;
    final finished = [for (final list in _jobs.values) ...list];
    return {
      'jobs_per_minute': within(finished, const Duration(minutes: 1)),
      'jobs_past_hour': within(finished, const Duration(hours: 1)),
      'failed_past_week': within(_jobs['failed']!, const Duration(days: 7)),
    };
  }

  /// Takes a metric snapshot (`horizon:snapshot`): per job name and per
  /// queue, the jobs finished since the previous one and their average run
  /// time; the last [maxSnapshots] of each are kept.
  void snapshot() {
    final now = _now;
    final since = _lastSnapshotAt ?? now - retention.inMilliseconds;
    _lastSnapshotAt = now;
    final byJob = <String, List<RecordedJob>>{};
    final byQueue = <String, List<RecordedJob>>{};
    for (final list in _jobs.values) {
      for (final job in list) {
        if (job.at > since && job.at <= now) {
          byJob.putIfAbsent(job.name, () => []).add(job);
          byQueue.putIfAbsent(job.queue, () => []).add(job);
        }
      }
    }
    void add(
      Map<String, List<Map<String, Object?>>> into,
      Map<String, List<RecordedJob>> groups,
    ) {
      for (final name in {...into.keys, ...groups.keys}) {
        final jobs = groups[name] ?? const <RecordedJob>[];
        final timed = [for (final j in jobs) ?j.durationMs];
        final list = into.putIfAbsent(name, () => [])
          ..add({
            'at': now,
            'count': jobs.length,
            'avg_ms': timed.isEmpty
                ? null
                : timed.reduce((a, b) => a + b) / timed.length,
          });
        if (list.length > maxSnapshots) {
          list.removeRange(0, list.length - maxSnapshots);
        }
      }
    }

    add(_jobSnapshots, byJob);
    add(_queueSnapshots, byQueue);
  }

  /// Records stay: they describe jobs, not the worker's state.
  @override
  void forgetWorker(String worker) {}

  @override
  Map<String, Object?> stats() => <String, Object?>{
    for (final MapEntry(:key, :value) in _jobs.entries) key: value.length,
  };
}
