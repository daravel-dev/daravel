import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

/// Opens [path] in WAL mode with a table of sequential ids.
Database openApp(String path) {
  final db = sqlite3.open(path)
    ..execute('PRAGMA journal_mode=WAL')
    ..execute('PRAGMA busy_timeout=5000')
    ..execute(
      'CREATE TABLE IF NOT EXISTS rows (id INTEGER PRIMARY KEY, body TEXT)',
    );
  return db;
}

void insert(Database db, int id) =>
    db.execute('INSERT INTO rows VALUES (?, ?)', [id, 'row $id ' * 40]);

/// The ids of the database at [path], in order.
List<int> ids(String path) {
  final db = sqlite3.open(path);
  try {
    return [
      for (final row in db.select('SELECT id FROM rows ORDER BY id'))
        row['id'] as int,
    ];
  } finally {
    db.close();
  }
}

/// Every committed state is a prefix 1..k: a restore must give one.
void expectPrefix(List<int> got, {int atLeast = 0}) {
  expect(got, [for (var i = 1; i <= got.length; i++) i]);
  expect(got.length, greaterThanOrEqualTo(atLeast));
}

/// Writes ids from [start] in their own transactions, now and then
/// checkpointing as an application would, until told to stop; answers
/// with the last id written.
Future<void> _writer((SendPort, String, int) args) async {
  final (reply, path, start) = args;
  final control = ReceivePort();
  reply.send(control.sendPort);
  var stop = false;
  control.listen((_) => stop = true);
  final db = openApp(path)..execute('PRAGMA busy_timeout=50');
  final random = math.Random(start);
  var id = start;
  while (!stop) {
    insert(db, id++);
    if (random.nextInt(40) == 0) {
      try {
        db.execute(
          'PRAGMA wal_checkpoint(${random.nextBool() ? 'PASSIVE' : 'RESTART'})',
        );
      } on SqliteException {
        // Busy: the replicator holds a read transaction. Fine.
      }
    }
    if (id % 25 == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  db.close();
  reply.send(id - 1);
  control.close();
}

/// Syncs every 10 ms, reporting each sync, until the isolate is killed.
Future<void> _replicate((SendPort, String, String) args) async {
  final (report, path, root) = args;
  final replicator = SqliteReplicator(
    path,
    LocalDisk('replica', root),
    checkpointPages: 30,
  );
  while (true) {
    await replicator.sync();
    report.send(true);
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory dir;
  late String path;
  late LocalDisk disk;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('daravel_repl_');
    path = p.join(dir.path, 'app.sqlite');
    disk = LocalDisk('replica', p.join(dir.path, 'replica'));
  });
  tearDown(() async {
    for (var i = 0; i < 20; i++) {
      try {
        dir.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        // Windows: a killed process may hold a file a moment longer.
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  String restored([String name = 'restored.sqlite']) => p.join(dir.path, name);

  test('snapshot, then the log; a restore equals the database', () async {
    final app = openApp(path);
    for (var i = 1; i <= 50; i++) {
      insert(app, i);
    }
    final replicator = SqliteReplicator(path, disk);
    final first = await replicator.sync();
    expect(first.newGeneration, isTrue);
    expect(first.reason, 'start');
    for (var i = 51; i <= 120; i++) {
      insert(app, i);
    }
    final second = await replicator.sync();
    expect(second.newGeneration, isFalse);
    expect(second.frames, greaterThan(0));
    replicator.close();
    app.close();

    final result = await restoreReplica(disk, '', restored());
    expect(result.generation, first.generation);
    expect(ids(restored()), [for (var i = 1; i <= 120; i++) i]);
    await expectLater(
      restoreReplica(disk, '', restored()),
      throwsA(isA<ReplicationException>()),
      reason: 'never overwrites without asking',
    );
  });

  test(
    'its own checkpoints restart the log without a new generation',
    () async {
      final app = openApp(path);
      final replicator = SqliteReplicator(path, disk, checkpointPages: 10);
      await replicator.sync();
      final reasons = <String?>[];
      for (var round = 0; round < 15; round++) {
        for (var i = 0; i < 8; i++) {
          insert(app, round * 8 + i + 1);
        }
        final sync = await replicator.sync();
        if (sync.newGeneration) {
          reasons.add(sync.reason);
        }
      }
      replicator.close();
      app.close();
      expect(reasons, isEmpty, reason: 'every restart was followed');
      await restoreReplica(disk, '', restored());
      expect(ids(restored()), [for (var i = 1; i <= 120; i++) i]);
    },
  );

  test('a log truncated behind its back starts a generation, losing '
      'nothing', () async {
    final app = openApp(path);
    final replicator = SqliteReplicator(path, disk);
    await replicator.sync();
    for (var i = 1; i <= 30; i++) {
      insert(app, i);
    }
    // The replicator is down (its read transaction gone) while the
    // application truncates the log and writes on.
    replicator.close();
    app.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    for (var i = 31; i <= 60; i++) {
      insert(app, i);
    }
    final sync = await replicator.sync();
    expect(sync.newGeneration, isTrue);
    expect(sync.reason, anyOf('log restarted', 'log truncated'));
    replicator.close();
    app.close();
    await restoreReplica(disk, '', restored());
    expect(ids(restored()), [for (var i = 1; i <= 60; i++) i]);
    expect(
      await listReplicaGenerations(disk, ''),
      hasLength(2),
      reason: 'retain: 2',
    );
  });

  test('under concurrent writes and checkpoints every restore is a '
      'committed prefix, and the last equals the database', () async {
    openApp(path).close();
    final replies = ReceivePort();
    final events = StreamIterator(replies);
    await Isolate.spawn(_writer, (replies.sendPort, path, 1));
    await events.moveNext();
    final control = events.current as SendPort;

    final replicator = SqliteReplicator(path, disk, checkpointPages: 20);
    final deadline = DateTime.now().add(const Duration(seconds: 4));
    var restores = 0;
    var newGenerations = 0;
    while (DateTime.now().isBefore(deadline)) {
      if ((await replicator.sync()).newGeneration) {
        newGenerations++;
      }
      if (restores < 6 && DateTime.now().millisecond < 200) {
        final target = restored('mid-$restores.sqlite');
        await restoreReplica(disk, '', target);
        expectPrefix(ids(target));
        restores++;
      }
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }
    control.send('stop');
    await events.moveNext();
    final last = events.current as int;
    replies.close();
    await replicator.sync();
    replicator.close();

    await restoreReplica(disk, '', restored());
    final got = ids(restored());
    expectPrefix(got);
    expect(got.length, last, reason: 'nothing committed is missing');
    expect(last, greaterThan(500), reason: 'the writer kept writing');
    // ignore: avoid_print
    print(
      '$last rows, $newGenerations generations after the first, '
      '$restores restores midway',
    );
  });

  test('point in time: the state as of a moment', () async {
    var now = DateTime.utc(2026, 10, 29, 8);
    final app = openApp(path);
    final replicator = SqliteReplicator(path, disk, clock: () => now);
    for (var i = 1; i <= 10; i++) {
      insert(app, i);
    }
    await replicator.sync();
    now = now.add(const Duration(minutes: 5));
    for (var i = 11; i <= 20; i++) {
      insert(app, i);
    }
    await replicator.sync();
    now = now.add(const Duration(minutes: 5));
    for (var i = 21; i <= 30; i++) {
      insert(app, i);
    }
    await replicator.sync();
    replicator.close();
    app.close();

    await restoreReplica(
      disk,
      '',
      restored(),
      at: DateTime.utc(2026, 10, 29, 8, 7),
    );
    expect(ids(restored()), [for (var i = 1; i <= 20; i++) i]);
  });

  test(
    'kill -9 of the replicator: a restore is a prefix with everything '
    'it confirmed',
    () async {
      final app = openApp(path);
      insert(app, 1);
      final child = await Process.start(Platform.resolvedExecutable, [
        'run',
        p.join('test', 'replication', 'support', 'replicate_main.dart'),
        path,
        disk.root,
      ]);
      final lines = StreamIterator(
        child.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final errors = StringBuffer();
      child.stderr.transform(utf8.decoder).listen(errors.write);
      Future<void> syncs(int n) async {
        for (var i = 0; i < n; i++) {
          if (!await lines.moveNext()) {
            fail(
              'the replicator exited (${await child.exitCode}): $errors '
              '${Platform.resolvedExecutable}',
            );
          }
        }
      }

      await syncs(1).timeout(const Duration(seconds: 120));
      var id = 1;
      var confirmed = 0;
      final random = math.Random(7);
      for (var round = 0; round < 30; round++) {
        for (var i = 0; i < 10 + random.nextInt(20); i++) {
          insert(app, ++id);
        }
        if (round % 3 == 0) {
          // Two syncs that began after these writes: they are shipped.
          await syncs(2).timeout(const Duration(seconds: 20));
          confirmed = id;
        }
      }
      // Writes in flight, then the process dies with no chance to finish.
      for (var i = 0; i < 15; i++) {
        insert(app, ++id);
      }
      child.kill(ProcessSignal.sigkill);
      await child.exitCode;
      app.close();

      await restoreReplica(disk, '', restored());
      expectPrefix(ids(restored()), atLeast: confirmed);
    },
    timeout: const Timeout(Duration(minutes: 3)),
    // `dart run` in the child copies the SQLite library, which this
    // process holds open on Windows. The isolate test below runs there.
    skip: Platform.isWindows ? 'the child cannot share the SQLite DLL' : false,
  );

  test('a replicator isolate killed mid-flight: the same guarantee', () async {
    final app = openApp(path);
    insert(app, 1);
    final ready = ReceivePort();
    final syncs = StreamIterator(ready);
    final isolate = await Isolate.spawn(_replicate, (
      ready.sendPort,
      path,
      disk.root,
    ));
    await syncs.moveNext();
    var id = 1;
    var confirmed = 0;
    for (var round = 0; round < 30; round++) {
      for (var i = 0; i < 25; i++) {
        insert(app, ++id);
      }
      if (round % 3 == 0) {
        await syncs.moveNext();
        await syncs.moveNext();
        confirmed = id;
      }
    }
    for (var i = 0; i < 15; i++) {
      insert(app, ++id);
    }
    isolate.kill(priority: Isolate.immediate);
    ready.close();
    app.close();
    await restoreReplica(disk, '', restored());
    expectPrefix(ids(restored()), atLeast: confirmed);
  });
}
