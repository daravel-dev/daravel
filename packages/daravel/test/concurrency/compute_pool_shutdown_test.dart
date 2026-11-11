import 'dart:async';
import 'dart:isolate';

import 'package:daravel/src/concurrency/compute_pool.dart';
import 'package:test/test.dart';

int answer() => 42;

/// An isolate whose last step is the pool's shutdown, as a command whose
/// last step is `app.shutdown()` after hashing a password: nothing else
/// keeps it alive while it waits for the workers to exit.
Future<void> lastStepShutdown(SendPort report) async {
  final pool = ComputePool(() => 2);
  await pool.run(answer);
  await pool.shutdown();
  report.send('done');
}

/// `shutdown()` waits for each worker's exit on a port that does not keep
/// the isolate alive: without more, an isolate with nothing else to do
/// ended inside that wait, so its shutdown never returned and whatever came
/// after it never ran (a command's output, the rest of `app.shutdown()`).
/// Seen on Linux every time: `bench/interop/laravel_matrix.sh` printed
/// nothing for each step that hashed.
void main() {
  test('shutdown completes in an isolate with nothing else to do', () async {
    for (var round = 0; round < 10; round++) {
      final report = ReceivePort();
      final exited = ReceivePort();
      await Isolate.spawn(
        lastStepShutdown,
        report.sendPort,
        onExit: exited.sendPort,
      );
      // Closed below without a message when the isolate ended early.
      final done = report.first.then((_) => true, onError: (Object _) => false);
      final gone = exited.first.then((_) => false);
      final finished = await Future.any([done, gone]);
      // The exit message follows `done`; let both arrive.
      await gone;
      report.close();
      expect(finished, isTrue, reason: 'round $round: exited inside shutdown');
    }
  });
}
