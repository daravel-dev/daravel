import 'dart:async';
import 'dart:io';

import 'package:daravel_session/daravel_session.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// The file driver's sweep on directories of tens of thousands of
/// sessions: the event loop keeps turning (a 10 ms timer is never late by
/// 100 ms or more), and expired files listed behind more active files than
/// one call examines are reached. Slow to set up, so only with
/// `DARAVEL_SESSION_GC_LOAD=1`.
void main() {
  final enabled = Platform.environment['DARAVEL_SESSION_GC_LOAD'] == '1';
  const lifetime = Duration(minutes: 120);
  late Directory base;

  setUp(() {
    base = Directory.systemTemp.createTempSync('daravel_session_gc_load_');
  });

  tearDown(() {
    if (base.existsSync()) {
      base.deleteSync(recursive: true);
    }
  });

  void files(String dir, String prefix, int count, {Duration? age}) {
    Directory(dir).createSync(recursive: true);
    final stamp = age == null ? null : DateTime.now().subtract(age);
    for (var i = 0; i < count; i++) {
      final file = File(p.join(dir, '$prefix${'$i'.padLeft(6, '0')}'))
        ..writeAsStringSync('a:0:{}');
      if (stamp != null) {
        file.setLastModifiedSync(stamp);
      }
    }
  }

  int count(String dir, String prefix) =>
      Directory(dir)
          .listSync()
          .where((e) => p.basename(e.path).startsWith(prefix))
          .length;

  /// Runs [handler]'s sweep until no `old` file is left (at most
  /// [maxCalls] calls) with a 10 ms timer measuring how late the event loop
  /// lets it fire; returns the calls and the worst lateness.
  Future<(int, Duration)> sweep(
    FileSessionHandler handler,
    String dir,
    String prefix, {
    int maxCalls = 200,
  }) async {
    var worst = Duration.zero;
    var last = DateTime.now();
    var measuring = true;
    final pinger = Timer.periodic(const Duration(milliseconds: 10), (_) {
      final now = DateTime.now();
      final late = now.difference(last) - const Duration(milliseconds: 10);
      if (measuring && late > worst) {
        worst = late;
      }
      last = now;
    });
    var calls = 0;
    final watch = Stopwatch()..start();
    try {
      while (calls < maxCalls) {
        await handler.gc(lifetime);
        calls++;
        // A call that held the loop until now delayed the tick due since
        // `last`, which would only fire after `measuring` is off: count the
        // gap here, as the late tick would have.
        final held =
            DateTime.now().difference(last) - const Duration(milliseconds: 10);
        if (held > worst) {
          worst = held;
        }
        // `count` lists synchronously: keep it out of the measurement,
        // including the tick it delays.
        measuring = false;
        final remaining = count(dir, prefix);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        last = DateTime.now();
        measuring = true;
        if (remaining == 0) {
          break;
        }
      }
    } finally {
      pinger.cancel();
    }
    printOnFailure('$calls calls, ${watch.elapsed}, worst lateness $worst');
    print('$calls calls in ${watch.elapsed}, worst timer lateness $worst');
    return (calls, worst);
  }

  test(
    '50 000 expired and 50 000 active files: the event loop is never held '
    'for 100 ms',
    () async {
      final dir = p.join(base.path, 'sessions');
      files(dir, 'active', 50000);
      files(dir, 'old', 50000, age: const Duration(hours: 3));
      final handler = FileSessionHandler(dir, lifetime: lifetime);
      final (_, worst) = await sweep(handler, dir, 'old');
      expect(count(dir, 'old'), 0);
      expect(count(dir, 'active'), 50000);
      expect(worst, lessThan(const Duration(milliseconds: 100)));
    },
    skip: enabled ? false : 'DARAVEL_SESSION_GC_LOAD=1 runs it',
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test(
    '5 000 expired files listed after 50 000 active ones are all reached',
    () async {
      final dir = p.join(base.path, 'sessions');
      files(dir, 'a', 50000);
      files(dir, 'old', 5000, age: const Duration(hours: 3));
      final handler = FileSessionHandler(dir, lifetime: lifetime);
      final (calls, worst) = await sweep(handler, dir, 'old');
      expect(count(dir, 'old'), 0, reason: 'after $calls calls');
      expect(count(dir, 'a'), 50000);
      expect(worst, lessThan(const Duration(milliseconds: 100)));
    },
    skip: enabled ? false : 'DARAVEL_SESSION_GC_LOAD=1 runs it',
    timeout: const Timeout(Duration(minutes: 20)),
  );
}
