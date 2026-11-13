import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `Cache.lock` on the `file` store holds across processes sharing the
/// directory (the lock file) and across the isolates of one process (the
/// coordinator), in two layers that are held or released together
/// (LK-1 item 3).
void main() {
  late Directory temp;
  late String kernel;

  setUpAll(() async {
    final build = await Directory.systemTemp.createTemp('daravel_lock_kernel_');
    kernel = p.join(build.path, 'file_lock_worker.dill');
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'kernel',
      p.join('test', 'cache', 'fixtures', 'file_lock_worker.dart'),
      '-o',
      kernel,
    ]);
    expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
  });

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('daravel_file_locks_');
  });

  tearDown(() => _deleteDirectory(temp));

  String cachePath() => p.join(temp.path, 'cache');

  Application app() => Application.configure(basePath: temp.path)
      .withEnv({
        'APP_ENV': 'testing',
        'DB_DATABASE': ':memory:',
        'CACHE_STORE': 'file',
        'CACHE_PATH': cachePath(),
        'QUEUE_SIGNAL_STORE': 'file',
      })
      .withLogLevel(LogLevel.critical)
      .create();

  /// Starts a worker [mode] and waits for its first line.
  Future<(Process, String)> holder(List<String> args) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      kernel,
      ...args,
    ]);
    final line = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 60));
    return (process, line);
  }

  test(
    'two processes taking Cache.lock never hold it at once',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      final marker = p.join(temp.path, 'marker');
      File(marker).writeAsStringSync('');
      final results = await Future.wait([
        for (final id in ['a', 'b'])
          Process.run(Platform.resolvedExecutable, [
            kernel,
            'contend',
            cachePath(),
            '40',
            id,
            marker,
          ]),
      ]);
      for (final result in results) {
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
    },
  );

  test(
    'a process killed while holding the lock keeps it until its time to '
    'live, not after',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final (process, line) = await holder(['hold', cachePath(), 'crash', '4']);
      expect(line, 'held');
      final killedAt = DateTime.now();
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
      final here = app();
      await here.boot();
      addTearDown(here.shutdown);
      await here.run(() async {
        expect(
          await Cache.lock('crash').acquire(),
          isFalse,
          reason: 'the dead process still holds it',
        );
        final wait =
            const Duration(seconds: 5) - DateTime.now().difference(killedAt);
        if (wait > Duration.zero) {
          await Future<void>.delayed(wait);
        }
        expect(await Cache.lock('crash').acquire(), isTrue, reason: 'expired');
      });
    },
  );

  test(
    'retry-all in this process while another process runs it throws '
    'RetryAllRunningException (the file signal store)',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      final (process, line) = await holder(['hold-retry-all', cachePath()]);
      addTearDown(() async {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode;
      });
      expect(line, 'held');
      final here = app();
      await here.boot();
      addTearDown(here.shutdown);
      await here.run(() async {
        await expectLater(
          Queue.manager.retryAllFailed(),
          throwsA(isA<RetryAllRunningException>()),
        );
      });
    },
  );

  group('two layers', () {
    late ProcessStore isolates;
    late FileStore one;
    late FileStore two;

    setUp(() {
      // Two stores on one directory and one coordinator: two isolates of a
      // process. On POSIX the OS lock of a lock file is the process's, so
      // the lock file alone would let both in.
      isolates = ProcessStore(
        LocalCoordinatorChannel(createStandardCoordinator()),
      );
      one = FileStore(cachePath(), isolateLocks: isolates);
      two = FileStore(cachePath(), isolateLocks: isolates);
    });

    // Only Linux (POSIX) tells this apart: without the coordinator layer,
    // two FileStores of one isolate both held the lock in 200 of 200 rounds
    // there (fcntl locks are the process's), and in 0 of 200 on Windows,
    // where LockFileEx already excludes another handle of the process.
    test('contenders of both stores: exactly one holds it', () async {
      final taken = await Future.wait([
        for (var i = 0; i < 40; i++)
          (i.isEven ? one : two).acquireLock(
            'shared',
            'owner$i',
            const Duration(seconds: 30),
          ),
      ]);
      expect(taken.where((t) => t), hasLength(1));
    });

    test('the lock file refusing releases the first layer again: no layer '
        'is left held alone', () async {
      const ttl = Duration(seconds: 30);
      expect(await one.acquireLock('shared', 'x', ttl), isTrue);
      // The first layer expired (or was lost) while the lock file holds.
      await isolates.forceReleaseLock('shared');
      expect(await two.acquireLock('shared', 'y', ttl), isFalse);
      expect(
        await isolates.lockOwner('shared'),
        isNull,
        reason: "y's first layer was released when the file refused it",
      );
      expect(await one.lockOwner('shared'), 'x');
      expect(await one.releaseLock('shared', 'x'), isTrue);
      expect(await two.acquireLock('shared', 'y', ttl), isTrue);
    });

    test('release and force release free both layers; the same owner '
        'extends both', () async {
      const ttl = Duration(seconds: 30);
      expect(await one.acquireLock('shared', 'x', ttl), isTrue);
      expect(
        await one.acquireLock('shared', 'x', ttl),
        isTrue,
        reason: 'extend',
      );
      expect(await isolates.lockOwner('shared'), 'x');
      expect(await one.releaseLock('shared', 'y'), isFalse, reason: 'not y');
      expect(await one.releaseLock('shared', 'x'), isTrue);
      expect(await isolates.lockOwner('shared'), isNull);
      expect(await two.acquireLock('shared', 'y', ttl), isTrue);
      await one.forceReleaseLock('shared');
      expect(await isolates.lockOwner('shared'), isNull);
      expect(await one.lockOwner('shared'), isNull);
    });
  });
}

/// Deletes [directory], trying again for a while: Windows refuses to delete
/// a file another handle still has open.
Future<void> _deleteDirectory(Directory directory) async {
  final waited = Stopwatch()..start();
  while (true) {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      return;
    } on FileSystemException {
      if (waited.elapsed > const Duration(seconds: 10)) {
        rethrow;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
