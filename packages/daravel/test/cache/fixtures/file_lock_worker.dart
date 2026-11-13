import 'dart:io';

import 'package:daravel/daravel.dart';

/// One process of `file_store_locks_test.dart`, an application with
/// `CACHE_STORE=file` in the directory given as second argument:
///
/// - `contend <dir> <rounds> <id> <marker>`: takes `Cache.lock('shared')`
///   [rounds] times; while holding it, writes [id] into [marker], waits and
///   checks it is still there, then empties it. Exit code 3 when another
///   holder was seen inside.
/// - `hold <dir> <name> <seconds>`: takes `Cache.lock(name)` for that long,
///   prints `held` (or `refused`) and waits to be killed.
/// - `hold-retry-all <dir>`: takes the queue's `queue:retry-all` lock in
///   its signal store, prints `held` and waits to be killed.
Future<void> main(List<String> args) async {
  final app = Application.configure(basePath: Directory.systemTemp.path)
      .withEnv({
        'APP_ENV': 'testing',
        'DB_DATABASE': ':memory:',
        'CACHE_STORE': 'file',
        'CACHE_PATH': args[1],
        'QUEUE_SIGNAL_STORE': 'file',
      })
      .withLogLevel(LogLevel.critical)
      .create();
  await app.boot();
  await app.run(() async {
    switch (args[0]) {
      case 'contend':
        final rounds = int.parse(args[2]);
        final id = args[3];
        final marker = File(args[4]);
        var held = 0;
        while (held < rounds) {
          final lock = Cache.lock('shared', ttl: const Duration(seconds: 30));
          if (!await lock.acquire()) {
            await Future<void>.delayed(const Duration(milliseconds: 1));
            continue;
          }
          final before = marker.existsSync() ? marker.readAsStringSync() : '';
          if (before.isNotEmpty) {
            stderr.writeln('$id saw $before inside');
            exitCode = 3;
          }
          marker.writeAsStringSync(id);
          await Future<void>.delayed(const Duration(milliseconds: 2));
          final after = marker.readAsStringSync();
          if (after != id) {
            stderr.writeln('$id found $after inside');
            exitCode = 3;
          }
          marker.writeAsStringSync('');
          await lock.release();
          held++;
        }
      case 'hold':
        final lock = Cache.lock(
          args[2],
          ttl: Duration(seconds: int.parse(args[3])),
        );
        stdout.writeln(await lock.acquire() ? 'held' : 'refused');
        await stdout.flush();
        await Future<void>.delayed(const Duration(minutes: 5));
      case 'hold-retry-all':
        final lock = Queue.manager.signalStore!.lock(
          'queue:retry-all',
          ttl: const Duration(minutes: 5),
        );
        stdout.writeln(await lock.acquire() ? 'held' : 'refused');
        await stdout.flush();
        await Future<void>.delayed(const Duration(minutes: 5));
    }
  });
  await app.shutdown();
}
