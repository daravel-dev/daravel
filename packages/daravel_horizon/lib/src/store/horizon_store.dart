import 'dart:convert';

import 'package:daravel/daravel.dart';

import 'process_store.dart';

/// Where Horizon keeps what it shows: the jobs its workers finished, the
/// tags it monitors and the metric snapshots (`HORIZON_STORE`).
///
/// The workers write to it, and the master and the dashboard read it, in
/// whichever isolate or process they run: a store that outlives a process
/// (`database`, `redis`) lets a dashboard served elsewhere read what the
/// master's workers recorded. `process`, the default, keeps everything in
/// this process's coordinator ([ProcessHorizonStore]).
///
/// The master's status (running or paused, its workers) is not here: it
/// lives in the queue's signal store (`HorizonSignals`).
///
/// The answers have the shapes the dashboard's JSON API serves as they are.
abstract interface class HorizonStore {
  /// Records [job], finished. Best effort: a job missing from the dashboard
  /// is harmless, so a store may drop it under load or on an error, and
  /// never throws. Idempotent per job: recording the same uuid again
  /// replaces its record, and an older record (an earlier `at`) never
  /// replaces a newer one. Such an older record still counts ([rates],
  /// [summary], snapshots: what it reports happened), but joins neither
  /// the lists nor a monitored tag's jobs.
  Future<void> record(RecordedJob job);

  /// The recorded jobs of [status] (`completed`, `failed`, `silenced`),
  /// newest first, [offset] skipped.
  Future<List<RecordedJob>> recent(
    String status, {
    int limit = 50,
    int offset = 0,
  });

  /// The recorded job [uuid], or null.
  Future<RecordedJob?> job(String uuid);

  /// Jobs of [queue] finished in the last minute: `per_second`, and the
  /// average run time `avg_ms` (null without one).
  Future<Map<String, Object?>> rates(String queue);

  /// `jobs_per_minute`, `jobs_past_hour` and `failed_past_week`. The
  /// `process` store keeps at most `HorizonService.maxPerStatus` (1 000)
  /// jobs of each status, so its counts stop there, as before; the
  /// `database` store counts every row of `horizon_job_counts` within the
  /// retention, without that cap.
  Future<Map<String, Object?>> summary();

  /// Keeps the jobs carrying [tag] apart, with the failed retention.
  Future<void> monitor(String tag);

  /// Stops monitoring [tag].
  Future<void> unmonitor(String tag);

  /// The monitored tags: `tag` and `count` of jobs kept for it.
  Future<List<Map<String, Object?>>> monitored();

  /// The jobs kept for monitored [tag], newest first.
  Future<List<RecordedJob>> tagged(String tag, {int limit = 50});

  /// Takes a metric snapshot (`horizon:snapshot`).
  Future<void> snapshot();

  /// The snapshots: `jobs` and `queues`, each a map from name to its
  /// snapshots (`at`, `count`, `avg_ms`).
  Future<Map<String, Object?>> metrics();
}

/// The `process` store: [HorizonService] in this process's coordinator,
/// reached through its [CoordinatorChannel] from any isolate of the
/// process. What Horizon kept before the store had a contract.
final class ProcessHorizonStore implements HorizonStore {
  /// The store behind [channel], read when used (the coordinator a worker
  /// isolate talks to is set up after its application is built).
  ProcessHorizonStore(this._channel);

  final CoordinatorChannel Function() _channel;

  Future<Object?> _call(String op, [Map<String, Object?> args = const {}]) =>
      _channel().call(HorizonService.serviceName, op, args);

  static Object? _decoded(Object? answer) =>
      answer is String ? jsonDecode(answer) : answer;

  static List<RecordedJob> _jobs(Object? answer) => [
    for (final job in (_decoded(answer) as List<Object?>? ?? const []))
      RecordedJob.fromJson(job! as Map<String, Object?>),
  ];

  @override
  Future<void> record(RecordedJob job) => _channel()
      .callBulk(
        HorizonService.serviceName,
        'record',
        {'job': jsonEncode(job.toJson())},
        // A flood of finished jobs keeps the newest records.
        overflow: BulkOverflow.dropOldest,
      )
      .then<void>((_) {}, onError: (Object _) {});

  @override
  Future<List<RecordedJob>> recent(
    String status, {
    int limit = 50,
    int offset = 0,
  }) async => _jobs(
    await _call('recent', {'status': status, 'limit': limit, 'offset': offset}),
  );

  @override
  Future<RecordedJob?> job(String uuid) async {
    final answer = _decoded(await _call('job', {'uuid': uuid}));
    return answer == null
        ? null
        : RecordedJob.fromJson(answer as Map<String, Object?>);
  }

  @override
  Future<Map<String, Object?>> rates(String queue) async =>
      _decoded(await _call('rates', {'queue': queue}))! as Map<String, Object?>;

  @override
  Future<Map<String, Object?>> summary() async =>
      _decoded(await _call('summary'))! as Map<String, Object?>;

  @override
  Future<void> monitor(String tag) => _call('monitor', {'tag': tag});

  @override
  Future<void> unmonitor(String tag) => _call('unmonitor', {'tag': tag});

  @override
  Future<List<Map<String, Object?>>> monitored() async => [
    for (final entry
        in (_decoded(await _call('monitored')) as List<Object?>? ?? const []))
      entry! as Map<String, Object?>,
  ];

  @override
  Future<List<RecordedJob>> tagged(String tag, {int limit = 50}) async =>
      _jobs(await _call('tagged', {'tag': tag, 'limit': limit}));

  @override
  Future<void> snapshot() => _call('snapshot');

  @override
  Future<Map<String, Object?>> metrics() async =>
      _decoded(await _call('metrics'))! as Map<String, Object?>;
}

/// The [HorizonStore] of [container]: the one bound (`withHorizon()`, from
/// `HORIZON_STORE`), else the `process` store of its coordinator, as an
/// application without `withHorizon()` (a worker built for a test, say)
/// had before the store had a contract.
HorizonStore horizonStoreOf(Container container) =>
    container.bound<HorizonStore>()
    ? container.make<HorizonStore>()
    : ProcessHorizonStore(() => container.make<CoordinatorChannel>());
