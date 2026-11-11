/// The control protocol between the Horizon master and its worker isolates
/// (Blueprint #134 §3.4). Every message is `@pragma('vm:deeply-immutable')`
/// (final fields of strings, numbers, booleans and null), so it crosses
/// isolates by reference. A worker's `SendPort` travels on its own, first.
library;

/// A message from the master to a worker.
sealed class WorkerCommand {}

/// Poll [queues] (comma separated, in priority order) from the next job on.
/// Never empty: a worker with nothing to do is sent [Pause].
@pragma('vm:deeply-immutable')
final class Assign implements WorkerCommand {
  /// Poll the comma-separated [queues].
  const Assign(this.queues);

  /// The queues, comma separated.
  final String queues;

  /// [queues] as a list.
  List<String> get list => [
    for (final q in queues.split(','))
      if (q.trim().isNotEmpty) q.trim(),
  ];
}

/// Take no new job until [Resume]; the running one finishes.
@pragma('vm:deeply-immutable')
final class Pause implements WorkerCommand {
  /// Stop taking jobs.
  const Pause();
}

/// Take jobs again after [Pause].
@pragma('vm:deeply-immutable')
final class Resume implements WorkerCommand {
  /// Take jobs again.
  const Resume();
}

/// Stop after the running job ([graceful]) and exit.
@pragma('vm:deeply-immutable')
final class Stop implements WorkerCommand {
  /// Stop the worker.
  const Stop({this.graceful = true});

  /// Whether the running job may finish first.
  final bool graceful;
}

/// A message from a worker to the master.
sealed class WorkerReport {}

/// The worker [worker] booted and polls.
@pragma('vm:deeply-immutable')
final class Ready implements WorkerReport {
  /// Worker [worker] is ready.
  const Ready(this.worker, {this.sessions = ''});

  /// The worker's name (`horizon-<plan>-<n>`).
  final String worker;

  /// The server sessions of its open database connections
  /// ([encodeSessions]).
  final String sessions;
}

/// Sent every heartbeat interval: what the worker has done and is doing.
/// The master keeps [jobId] and [queue] of a running job, to reclaim it
/// if the worker stops answering.
@pragma('vm:deeply-immutable')
final class Heartbeat implements WorkerReport {
  /// The state of [worker] now.
  const Heartbeat(
    this.worker, {
    required this.processed,
    this.jobId,
    this.jobUuid,
    this.queue,
    this.jobReservedAtMs,
    this.jobTimeoutMs,
    this.jobName,
    this.attempt,
    this.sessions = '',
  });

  /// The worker's name.
  final String worker;

  /// Jobs it has finished.
  final int processed;

  /// The id in its queue of the job running now (as text), or null.
  final String? jobId;

  /// The UUID of the job running now.
  final String? jobUuid;

  /// The queue of the job running now.
  final String? queue;

  /// When the driver reserved that job (epoch milliseconds, wall clock):
  /// reported at once (`WorkerOptions.onReserved`), before the job is
  /// decoded or run. The master counts the job's limit from here, as the
  /// driver counts `retry_after`.
  final int? jobReservedAtMs;

  /// How long that job may run (milliseconds): the timeout the processor
  /// enforces (the plan's, otherwise the job's own; `JobProcessing.timeout`), which the master uses as is.
  final int? jobTimeoutMs;

  /// That job's name (its display name when it has one).
  final String? jobName;

  /// That job's attempt, from 1.
  final int? attempt;

  /// The server sessions of its open database connections
  /// ([encodeSessions]), for the master to end them after a kill.
  final String sessions;
}

/// The worker ended on its own with exit [code] (0, 1 for a restart the
/// worker asked for, 12 past the memory limit).
@pragma('vm:deeply-immutable')
final class Exited implements WorkerReport {
  /// [worker] exited with [code].
  const Exited(this.worker, this.code);

  /// The worker's name.
  final String worker;

  /// Its exit code.
  final int code;
}

/// `DatabaseManager.openSessions()` as one string a deeply-immutable message
/// can carry: `pgsql=812,815;audit=901`.
String encodeSessions(Map<String, List<String>> sessions) => [
  for (final MapEntry(:key, :value) in sessions.entries)
    if (value.isNotEmpty) '$key=${value.join(',')}',
].join(';');

/// The sessions [encodeSessions] wrote, by connection name.
Map<String, List<String>> decodeSessions(String sessions) => {
  for (final part in sessions.split(';'))
    if (part.indexOf('=') case final at when at > 0)
      part.substring(0, at): [
        for (final id in part.substring(at + 1).split(','))
          if (id.isNotEmpty) id,
      ],
};
