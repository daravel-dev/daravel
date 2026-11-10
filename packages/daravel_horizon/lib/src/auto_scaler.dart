import 'config.dart';

/// One queue of a supervisor, as measured for one evaluation.
final class QueueLoad {
  /// [size] jobs waiting on [queue], the oldest for [oldestWait]; the
  /// samples of this evaluation: [arrivalRate] jobs a second and
  /// [serviceTime] per job (null when nothing was measured).
  const QueueLoad({
    required this.queue,
    required this.size,
    this.oldestWait,
    this.arrivalRate,
    this.serviceTime,
    this.targetWait = const Duration(seconds: 60),
  });

  /// The queue.
  final QueueName queue;

  /// Jobs waiting (`QueueDriver.size`).
  final int size;

  /// How long the oldest ready job has waited (`QueueDriver.oldestWait`).
  final Duration? oldestWait;

  /// Jobs a second that arrived since the last evaluation.
  final double? arrivalRate;

  /// The average run time of the jobs finished since the last evaluation.
  final Duration? serviceTime;

  /// The wait the supervisor aims to stay under (`waits`).
  final Duration targetWait;
}

/// What [decide] reads: a plan and its queues' load.
final class ScalingInput {
  /// The [plan] under the load of [queues].
  const ScalingInput({
    required this.plan,
    required this.queues,
    this.alpha = 0.3,
    this.jobsPerProcess = 100,
  });

  /// The supervisor.
  final SupervisorPlan plan;

  /// The load of each of its queues.
  final List<QueueLoad> queues;

  /// EWMA smoothing (`HORIZON_EWMA_ALPHA`).
  final double alpha;

  /// Waiting jobs per worker of [AutoScalingStrategy.size].
  final int jobsPerProcess;
}

/// What [decide] remembers between evaluations.
final class ScalingState {
  /// [workers] running now, with the smoothed rates and the calm streak.
  const ScalingState({
    this.workers = 0,
    this.arrival = const {},
    this.service = const {},
    this.calm = 0,
  });

  /// Workers of the plan now.
  final int workers;

  /// Smoothed arrival rate per queue (jobs/s).
  final Map<String, double> arrival;

  /// Smoothed service time per queue (seconds).
  final Map<String, double> service;

  /// Evaluations in a row in which every queue waited under half its target
  /// (scaling down needs two).
  final int calm;
}

/// The workers a supervisor should run.
final class ScalingDecision {
  /// [total] workers: [perQueue] each on one queue, [shared] on every queue
  /// in priority order.
  const ScalingDecision({
    required this.total,
    required this.perQueue,
    required this.shared,
    required this.reason,
    required this.state,
  });

  /// Workers in all.
  final int total;

  /// Workers dedicated to one queue.
  final Map<String, int> perQueue;

  /// Workers polling every queue in priority order.
  final int shared;

  /// Why: `off`, `simple`, `scale-up`, `scale-down`, `hold`, `wait-calm`.
  final String reason;

  /// The state for the next evaluation.
  final ScalingState state;
}

/// `x̂ = α·x + (1 − α)·x̂₋₁`; the sample alone the first time.
double ewma(double? previous, double sample, double alpha) =>
    previous == null ? sample : alpha * sample + (1 - alpha) * previous;

/// The pool size and spread of [input]'s plan, from [previous]: pure and
/// deterministic (Blueprint #134 §3.5).
///
/// - [BalanceStrategy.off]: `maxProcesses` workers on every queue.
/// - [BalanceStrategy.simple]: `maxProcesses` split evenly (the rest to the
///   first queue).
/// - [BalanceStrategy.auto]: per queue `N = ceil(Q·T / W + λ·T)`
///   ([AutoScalingStrategy.time], λ and T smoothed) or
///   `ceil(Q / jobsPerProcess)` ([AutoScalingStrategy.size]); the sum
///   clamped to `[minProcesses, maxProcesses]`, moved at most
///   `balanceMaxShift` from the current size, and lowered only after two
///   evaluations in a row with every queue waiting under half its target.
///   Workers go to queues in proportion to their need, at least one to each
///   queue with jobs; the rest poll every queue.
ScalingDecision decide(ScalingInput input, ScalingState previous) {
  final plan = input.plan;
  final queues = [for (final q in plan.queues) q.value];
  switch (plan.balance) {
    case BalanceStrategy.off:
      return ScalingDecision(
        total: plan.maxProcesses,
        perQueue: const {},
        shared: plan.maxProcesses,
        reason: 'off',
        state: ScalingState(workers: plan.maxProcesses),
      );
    case BalanceStrategy.simple:
      final each = queues.isEmpty ? 0 : plan.maxProcesses ~/ queues.length;
      final rest = plan.maxProcesses - each * queues.length;
      return ScalingDecision(
        total: plan.maxProcesses,
        perQueue: {
          for (final (i, q) in queues.indexed) q: each + (i == 0 ? rest : 0),
        },
        shared: queues.isEmpty ? plan.maxProcesses : 0,
        reason: 'simple',
        state: ScalingState(workers: plan.maxProcesses),
      );
    case BalanceStrategy.auto:
      break;
  }
  final arrival = <String, double>{};
  final service = <String, double>{};
  final need = <String, int>{};
  var calmNow = true;
  for (final load in input.queues) {
    final name = load.queue.value;
    final lambda = load.arrivalRate == null
        ? (previous.arrival[name] ?? 0)
        : ewma(previous.arrival[name], load.arrivalRate!, input.alpha);
    final sample = load.serviceTime;
    final t = sample == null
        ? (previous.service[name] ?? 1.0)
        : ewma(
            previous.service[name],
            sample.inMicroseconds / Duration.microsecondsPerSecond,
            input.alpha,
          );
    arrival[name] = lambda;
    service[name] = t;
    final target =
        load.targetWait.inMicroseconds / Duration.microsecondsPerSecond;
    final n = switch (plan.autoScalingStrategy) {
      AutoScalingStrategy.time =>
        (load.size * t / (target <= 0 ? 1 : target) + lambda * t).ceil(),
      AutoScalingStrategy.size =>
        (load.size / (input.jobsPerProcess < 1 ? 1 : input.jobsPerProcess))
            .ceil(),
    };
    need[name] = n < 0 ? 0 : n;
    final waited = load.oldestWait ?? Duration.zero;
    if (waited * 2 >= load.targetWait) {
      calmNow = false;
    }
  }
  final min = plan.minProcesses < 0 ? 0 : plan.minProcesses;
  final max = plan.maxProcesses < min ? min : plan.maxProcesses;
  final shift = plan.balanceMaxShift < 1 ? 1 : plan.balanceMaxShift;
  final current = previous.workers.clamp(min, max);
  final wanted = need.values.fold(0, (a, b) => a + b).clamp(min, max);
  final calm = calmNow ? previous.calm + 1 : 0;
  int total;
  String reason;
  if (wanted > current) {
    total = current + (wanted - current > shift ? shift : wanted - current);
    reason = 'scale-up';
  } else if (wanted < current) {
    if (calm >= 2) {
      total = current - (current - wanted > shift ? shift : current - wanted);
      reason = 'scale-down';
    } else {
      total = current;
      reason = 'wait-calm';
    }
  } else {
    total = current;
    reason = 'hold';
  }
  final (perQueue, shared) = _spread(total, queues, need, input.queues);
  return ScalingDecision(
    total: total,
    perQueue: perQueue,
    shared: shared,
    reason: reason,
    state: ScalingState(
      workers: total,
      arrival: arrival,
      service: service,
      // A scale-down starts the count again.
      calm: reason == 'scale-down' ? 0 : calm,
    ),
  );
}

/// [total] workers over [queues] in proportion to [need], at least one for
/// each queue with jobs while there are workers left; the rest shared.
(Map<String, int>, int) _spread(
  int total,
  List<String> queues,
  Map<String, int> need,
  List<QueueLoad> loads,
) {
  final perQueue = {for (final q in queues) q: 0};
  final sum = need.values.fold(0, (a, b) => a + b);
  var left = total;
  if (sum > 0) {
    for (final q in queues) {
      final share = (total * (need[q] ?? 0)) ~/ sum;
      final given = share > left ? left : share;
      perQueue[q] = given;
      left -= given;
    }
  }
  final busy = {
    for (final load in loads)
      if (load.size > 0) load.queue.value,
  };
  for (final q in queues) {
    if (left == 0) {
      break;
    }
    if (busy.contains(q) && perQueue[q] == 0) {
      perQueue[q] = 1;
      left--;
    }
  }
  perQueue.removeWhere((_, n) => n == 0);
  return (perQueue, left);
}
