/// Events dispatched by the framework itself (BLUEPRINT_V2 §7.8).
library;

/// A job was reserved and is about to run.
final class JobProcessing {
  const JobProcessing({
    required this.connection,
    required this.queue,
    required this.jobName,
    required this.jobId,
    required this.attempt,
  });

  final String connection;
  final String queue;
  final String jobName;
  final Object jobId;
  final int attempt;
}

/// A job finished without error.
final class JobProcessed {
  const JobProcessed({
    required this.connection,
    required this.queue,
    required this.jobName,
    required this.jobId,
    required this.duration,
  });

  final String connection;
  final String queue;
  final String jobName;
  final Object jobId;
  final Duration duration;
}

/// A job threw; [willRetry] tells whether it was released for another try.
final class JobExceptionOccurred {
  const JobExceptionOccurred({
    required this.connection,
    required this.queue,
    required this.jobName,
    required this.jobId,
    required this.error,
    required this.willRetry,
  });

  final String connection;
  final String queue;
  final String jobName;
  final Object jobId;
  final Object error;
  final bool willRetry;
}

/// A job exhausted its attempts and was recorded in `failed_jobs`.
final class JobFailed {
  const JobFailed({
    required this.connection,
    required this.queue,
    required this.jobName,
    required this.jobId,
    required this.error,
  });

  final String connection;
  final String queue;
  final String jobName;
  final Object jobId;
  final Object error;
}

/// A scheduled task is about to run.
final class ScheduledTaskStarting {
  const ScheduledTaskStarting(this.task);

  final String task;
}

/// A scheduled task finished (successfully or not).
final class ScheduledTaskFinished {
  const ScheduledTaskFinished(this.task, this.duration, {this.error});

  final String task;
  final Duration duration;
  final Object? error;

  bool get succeeded => error == null;
}

/// A scheduled task was skipped (filter, overlap lock, environment).
final class ScheduledTaskSkipped {
  const ScheduledTaskSkipped(this.task, this.reason);

  final String task;
  final String reason;
}

/// A database transaction or savepoint began. [depth] is 1 for `BEGIN`.
final class TransactionBeginning {
  const TransactionBeginning(
    this.connection, {
    this.depth = 1,
    this.poolWait = Duration.zero,
  });

  final String connection;
  final int depth;

  /// The wait for a free connection.
  final Duration poolWait;
}

/// A database transaction committed, or a savepoint was released.
final class TransactionCommitted {
  const TransactionCommitted(
    this.connection, {
    this.depth = 1,
    this.elapsed = Duration.zero,
  });

  final String connection;
  final int depth;
  final Duration elapsed;
}

/// A database transaction or savepoint rolled back.
final class TransactionRolledBack {
  const TransactionRolledBack(
    this.connection, {
    this.depth = 1,
    this.elapsed = Duration.zero,
    this.error,
  });

  final String connection;
  final int depth;
  final Duration elapsed;
  final Object? error;
}
