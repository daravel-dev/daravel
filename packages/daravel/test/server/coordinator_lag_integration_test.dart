@Tags(['integration'])
library;

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// The real probe, on a real event loop (the rest of K1 is tested with
/// [Coordinator.observeLag]): blocking the loop well past the shedding
/// threshold makes the coordinator saturated, and it is healthy again once
/// the loop is free. Thresholds and waits are loose on purpose.
void main() {
  test(
    'a blocked event loop saturates the coordinator, which recovers',
    () async {
      final coordinator = createStandardCoordinator();
      addTearDown(coordinator.close);
      final channel = RemoteCoordinatorChannel(coordinator.listen());
      addTearDown(channel.close);
      // A call first: the coordinator learns this worker's port.
      await ProcessStore(channel).get('k1');

      final states = <CoordinatorState>[];
      channel.onStateChange = states.add;
      // Ten times the default shedding threshold (50 ms).
      final watch = Stopwatch()..start();
      while (watch.elapsed < const Duration(milliseconds: 500)) {}

      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!states.contains(CoordinatorState.healthy) &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(states.first, CoordinatorState.saturated);
      expect(states.last, CoordinatorState.healthy);
      expect(coordinator.state, CoordinatorState.healthy);
    },
  );
}
