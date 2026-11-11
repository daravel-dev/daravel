import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A bulk service whose answers wait until the test lets them go.
final class _Held with PrioritizedService implements CoordinatorService {
  final List<Object?> received = [];
  final List<Completer<Object?>> held = [];

  @override
  CoordinatorPriority get priority => CoordinatorPriority.bulk;

  @override
  String get name => 'held';

  @override
  Object? handle(String op, Map<String, Object?> args) {
    received.add(args['n']);
    final answer = Completer<Object?>();
    held.add(answer);
    return answer.future.then((_) => args['n']);
  }

  void releaseAll() {
    for (final answer in held) {
      answer.complete();
    }
    held.clear();
  }

  @override
  Map<String, Object?> stats() => const {};
}

/// A worker's application shutting down with bulk calls still in its
/// channel's buffer (K1b): they are flushed, bounded, before the detached
/// tasks (the channel's timeout sweep among them) stop.
void main() {
  late Coordinator coordinator;
  late _Held held;
  late RemoteCoordinatorChannel channel;
  late Application app;
  late MemoryHandler logs;

  setUp(() async {
    coordinator = Coordinator(probeEvery: const Duration(hours: 1));
    held = _Held();
    coordinator.register(held);
    channel = RemoteCoordinatorChannel(coordinator.listen(), bulkWindow: 1);
    app = Application.configure(basePath: Directory.systemTemp.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withLogLevel(LogLevel.debug)
        .create();
    app.coordinator = channel;
    await app.boot();
    logs = await app.run(() async => Log.spy());
  });
  tearDown(() {
    channel.close();
    coordinator.close();
  });

  test('bulk calls held in the buffer reach the coordinator before the '
      'application has shut down', () async {
    final answers = await app.run(
      () async => [
        for (var n = 0; n < 4; n++) channel.callBulk('held', 'x', {'n': n}),
      ],
    );
    // One in flight (window 1), three in the buffer.
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(held.received, [0]);
    Timer(const Duration(milliseconds: 100), () {
      // Each answer sends the next waiting call; let those go too.
      Timer.periodic(const Duration(milliseconds: 5), (timer) {
        held.releaseAll();
        if (held.received.length == 4 && held.held.isEmpty) {
          timer.cancel();
        }
      });
    });
    final watch = Stopwatch()..start();
    await app.shutdown();
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    expect(held.received, [0, 1, 2, 3]);
    expect(await Future.wait(answers), [0, 1, 2, 3]);
    expect(logs.matching(LogLevel.error, 'Detached task'), isEmpty);
  });

  test('a coordinator that never answers holds the shutdown at most the '
      'flush bound (two seconds); no call is lost unanswered', () async {
    final answers = await app.run(
      () async => [
        for (var n = 0; n < 4; n++)
          channel
              .callBulk('held', 'x', {'n': n})
              .then<Object?>((value) => value, onError: (Object e) => e),
      ],
    );
    final watch = Stopwatch()..start();
    await app.shutdown();
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 2500)));
    expect(logs.matching(LogLevel.error, 'Detached task'), isEmpty);
    // The calls not sent are failed when the channel closes, not lost.
    channel.close();
    final results = await Future.wait(answers);
    expect(results.whereType<CoordinatorException>(), hasLength(4));
  });
}
