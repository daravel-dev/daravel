/// Events dispatched by the framework itself (BLUEPRINT_V2 §7.8).
library;

/// A job was reserved and is about to run.
final class JobProcessing {
  /// A worker started a job.
  const JobProcessing({
    required this.connection,
    required this.queue,
    required this.jobName,
    required this.jobId,
    required this.attempt,
    this.uuid,
    this.displayName,
    this.tags = const <String>[],
    this.pushedAt,
    this.context,
  });

  /// The queue connection.
  final String connection;

  /// The queue.
  final String queue;

  /// The job's name.
  final String jobName;

  /// The job's id.
  final Object jobId;

  /// The attempt number, from 1.
  final int attempt;

  /// The dispatch's UUID, kept across retries (null when not known).
  final String? uuid;

  /// The name shown in logs and dashboards (null when not known).
  final String? displayName;

  /// The job's monitoring tags (`Job.tags`).
  final List<String> tags;

  /// When the job was first pushed (UTC), when the payload says.
  final DateTime? pushedAt;

  /// The dispatching scope's `Context`, as the payload carries it.
  final Map<String, Object?>? context;
}

/// A job finished without error.
final class JobProcessed {
  /// A job finished.
  const JobProcessed({
    required this.connection,
    required this.queue,
    required this.jobName,
    required this.jobId,
    required this.duration,
    this.uuid,
    this.attempt,
  });

  /// The queue connection.
  final String connection;

  /// The queue.
  final String queue;

  /// The job's name.
  final String jobName;

  /// The job's id.
  final Object jobId;

  /// How long it ran.
  final Duration duration;

  /// The dispatch's UUID (null when not known).
  final String? uuid;

  /// The attempt that succeeded, from 1 (null when not known).
  final int? attempt;
}

/// A job threw; [willRetry] tells whether it was released for another try.
final class JobExceptionOccurred {
  /// A job threw.
  const JobExceptionOccurred({
    required this.connection,
    required this.queue,
    required this.jobName,
    required this.jobId,
    required this.error,
    required this.willRetry,
    this.uuid,
    this.attempt,
    this.stackTrace,
  });

  /// The queue connection.
  final String connection;

  /// The queue.
  final String queue;

  /// The job's name.
  final String jobName;

  /// The job's id.
  final Object jobId;

  /// The error thrown.
  final Object error;

  /// Whether the job will be attempted again.
  final bool willRetry;

  /// The dispatch's UUID (null when not known).
  final String? uuid;

  /// The attempt that threw, from 1 (null when not known).
  final int? attempt;

  /// Where [error] was thrown (null when not known).
  final StackTrace? stackTrace;
}

/// A job exhausted its attempts and was recorded in `failed_jobs`.
final class JobFailed {
  /// A job failed for good.
  const JobFailed({
    required this.connection,
    required this.queue,
    required this.jobName,
    required this.jobId,
    required this.error,
    this.uuid,
    this.stackTrace,
    this.failedId,
  });

  /// The queue connection.
  final String connection;

  /// The queue.
  final String queue;

  /// The job's name.
  final String jobName;

  /// The job's id.
  final Object jobId;

  /// The last error.
  final Object error;

  /// The dispatch's UUID (null when not known).
  final String? uuid;

  /// Where [error] was thrown (null when not known).
  final StackTrace? stackTrace;

  /// The id of its `failed_jobs` entry (null when not recorded).
  final Object? failedId;
}

/// A scheduled task is about to run.
final class ScheduledTaskStarting {
  /// The scheduled [task] is starting.
  const ScheduledTaskStarting(this.task);

  /// The task's name.
  final String task;
}

/// A scheduled task finished (successfully or not).
final class ScheduledTaskFinished {
  /// The scheduled [task] finished after [duration].
  const ScheduledTaskFinished(this.task, this.duration, {this.error});

  /// The task's name.
  final String task;

  /// How long it ran.
  final Duration duration;

  /// The error it failed with, or null.
  final Object? error;

  /// Whether it succeeded.
  bool get succeeded => error == null;
}

/// A scheduled task was skipped (filter, overlap lock, environment).
final class ScheduledTaskSkipped {
  /// The scheduled [task] was skipped, for [reason].
  const ScheduledTaskSkipped(this.task, this.reason);

  /// The task's name.
  final String task;

  /// Why it was skipped.
  final String reason;
}

/// A database transaction or savepoint began. [depth] is 1 for `BEGIN`.
final class TransactionBeginning {
  /// A transaction or savepoint is starting.
  const TransactionBeginning(
    this.connection, {
    this.depth = 1,
    this.poolWait = Duration.zero,
  });

  /// The connection.
  final String connection;

  /// The nesting level, 1 for the outer transaction.
  final int depth;

  /// The wait for a free connection.
  final Duration poolWait;
}

/// A database transaction committed, or a savepoint was released.
final class TransactionCommitted {
  /// A transaction or savepoint committed.
  const TransactionCommitted(
    this.connection, {
    this.depth = 1,
    this.elapsed = Duration.zero,
  });

  /// The connection.
  final String connection;

  /// The nesting level.
  final int depth;

  /// How long it ran.
  final Duration elapsed;
}

/// A database transaction or savepoint rolled back.
final class TransactionRolledBack {
  /// A transaction or savepoint rolled back.
  const TransactionRolledBack(
    this.connection, {
    this.depth = 1,
    this.elapsed = Duration.zero,
    this.error,
  });

  /// The connection.
  final String connection;

  /// The nesting level.
  final int depth;

  /// How long it ran.
  final Duration elapsed;

  /// The error that rolled it back, or null.
  final Object? error;
}
