@Tags(['integration'])
library;

import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Sends [args].$2 calls to the coordinator's port ([args].$1) as fast as
/// it can, from another isolate: a queue the coordinator cannot keep up
/// with. The answers go to a port nobody reads.
void _flood((SendPort, int) args) {
  final (port, count) = args;
  final replies = RawReceivePort((Object? _) {});
  for (var i = 0; i < count; i++) {
    port.send(
      CoordinatorRequest(
        id: i,
        service: 'noop',
        op: 'x',
        args: const {},
        replyTo: replies.sendPort,
      ),
    );
  }
  replies.close();
}

final class _Noop implements CoordinatorService {
  @override
  String get name => 'noop';

  @override
  Object? handle(String op, Map<String, Object?> args) {
    // A little work per call, so the flood outruns the coordinator.
    final watch = Stopwatch()..start();
    while (watch.elapsedMicroseconds < 5) {}
    return null;
  }

  @override
  Map<String, Object?> stats() => const {};
}

Future<void> waitFor(bool Function() done, Duration within) async {
  final deadline = DateTime.now().add(within);
  while (!done() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// The real probe, on a real event loop (the rest of K1/K1b is tested with
/// [Coordinator.observeLag]). Thresholds and waits are loose on purpose.
void main() {
  test('a queue the coordinator cannot keep up with saturates it, and it '
      'recovers', () async {
    final coordinator = createStandardCoordinator()..register(_Noop());
    addTearDown(coordinator.close);
    final port = coordinator.listen();
    final channel = RemoteCoordinatorChannel(port);
    addTearDown(channel.close);
    final states = <CoordinatorState>[];
    channel.onStateChange = states.add;
    await ProcessStore(channel).get('k1');

    final exited = ReceivePort();
    await Isolate.spawn(_flood, (port, 400000), onExit: exited.sendPort);
    await exited.first;
    await waitFor(
      () => states.contains(CoordinatorState.healthy),
      const Duration(seconds: 20),
    );
    expect(states, contains(CoordinatorState.saturated));
    expect(states.last, CoordinatorState.healthy);
    expect(coordinator.state, CoordinatorState.healthy);
  });

  test('a blocked event loop with no queue behind is starvation: the '
      'coordinator stays healthy (§6.6)', () async {
    final coordinator = createStandardCoordinator();
    addTearDown(coordinator.close);
    final channel = RemoteCoordinatorChannel(coordinator.listen());
    addTearDown(channel.close);
    final states = <CoordinatorState>[];
    channel.onStateChange = states.add;
    await ProcessStore(channel).get('k1');

    // Ten times the default shedding threshold (50 ms).
    final watch = Stopwatch()..start();
    while (watch.elapsed < const Duration(milliseconds: 500)) {}

    await waitFor(
      () => (coordinator.stats()['starved_peak_ms']! as num) >= 300,
      const Duration(seconds: 5),
    );
    // A few more probes: still healthy.
    await Future<void>.delayed(Coordinator.lagProbeInterval * 5);
    expect(coordinator.stats()['starved_peak_ms'], greaterThanOrEqualTo(300));
    expect(states, isEmpty);
    expect(coordinator.state, CoordinatorState.healthy);
  });
}
