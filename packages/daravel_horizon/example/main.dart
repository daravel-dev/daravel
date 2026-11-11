import 'package:daravel_horizon/daravel_horizon.dart';

/// Sizes a supervisor for a backlog on its `high` queue.
void main() {
  const plan = SupervisorPlan(
    name: SupervisorName('supervisor-1'),
    queues: [QueueName('high'), QueueName('default')],
    maxProcesses: 8,
    balanceMaxShift: 2,
  );
  var state = const ScalingState(workers: 1);
  for (var i = 0; i < 4; i++) {
    final decision = decide(
      ScalingInput(
        plan: plan,
        queues: const [
          QueueLoad(
            queue: QueueName('high'),
            size: 600,
            serviceTime: Duration(milliseconds: 500),
            arrivalRate: 2,
          ),
          QueueLoad(queue: QueueName('default'), size: 0),
        ],
      ),
      state,
    );
    print(
      '${decision.reason}: ${decision.total} workers '
      '${decision.perQueue} + ${decision.shared} shared',
    );
    state = decision.state;
  }
}
