// A minimal reproduction, without Daravel, of the native crash in
// sqlite3.dll seen by bench/bin/horizon_isolates.dart on Windows: several
// isolates of one process using one SQLite file at once.
//
// ```bash
// dart run bin/sqlite_isolates_repro.dart a   # close() before the isolate ends
// dart run bin/sqlite_isolates_repro.dart b   # no close(): finalizers only
// dart run bin/sqlite_isolates_repro.dart c   # Isolate.kill while writing
// dart run bin/sqlite_isolates_repro.dart d   # Isolate.exit with a statement open
// ```
//
// Each run does three rounds of 8 isolates on one WAL file, each with its
// own connection inserting and selecting for half a second while the main
// isolate writes too, then ending the way the variant says. Prints `ok`, or
// the VM crashes.
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

final String _path =
    '${Directory.systemTemp.path}${Platform.pathSeparator}sqlite_repro_$pid.db';

typedef _Start = ({String variant, int index, SendPort done});

Future<void> _worker(_Start start) async {
  final db = sqlite3.open(_path)..execute('PRAGMA busy_timeout = 5000');
  final insert = db.prepare('INSERT INTO t (v) VALUES (?)');
  final select = db.prepare('SELECT count(*) FROM t');
  final until = DateTime.now().add(const Duration(milliseconds: 500));
  var i = 0;
  while (DateTime.now().isBefore(until)) {
    insert.execute(['w${start.index}-${i++}']);
    select.select();
    if (i % 20 == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  switch (start.variant) {
    case 'a':
      insert.close();
      select.close();
      db.close();
      start.done.send(i);
    case 'b':
      start.done.send(i); // statements and connection left to finalizers
    case 'c':
      start.done.send(i);
      // Keeps writing until the main isolate kills it.
      while (true) {
        insert.execute(['k${start.index}-${i++}']);
        if (i % 20 == 0) {
          await Future<void>.delayed(Duration.zero);
        }
      }
    case 'd':
      Isolate.exit(start.done, i); // a statement still prepared
  }
}

Future<void> main(List<String> args) async {
  final variant = args.isEmpty ? 'a' : args.first;
  if (File(_path).existsSync()) {
    File(_path).deleteSync();
  }
  final main = sqlite3.open(_path)
    ..execute('PRAGMA journal_mode = WAL')
    ..execute('PRAGMA busy_timeout = 5000')
    ..execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
  final mainInsert = main.prepare('INSERT INTO t (v) VALUES (?)');
  for (var round = 1; round <= 3; round++) {
    final done = ReceivePort();
    final isolates = <Isolate>[];
    for (var index = 0; index < 8; index++) {
      isolates.add(
        await Isolate.spawn(_worker, (
          variant: variant,
          index: index,
          done: done.sendPort,
        ), debugName: 'repro-$round-$index'),
      );
    }
    var finished = 0;
    final all = Completer<void>();
    done.listen((_) {
      if (++finished == 8 && !all.isCompleted) {
        all.complete();
      }
    });
    // The main isolate writes meanwhile.
    while (!all.isCompleted) {
      mainInsert.execute(['main-$round']);
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    if (variant == 'c') {
      for (final isolate in isolates) {
        isolate.kill(priority: Isolate.immediate);
      }
    }
    done.close();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    stdout.writeln('variant $variant round $round: ok');
  }
  mainInsert.close();
  main.close();
  for (final suffix in const ['', '-wal', '-shm']) {
    final file = File('$_path$suffix');
    if (file.existsSync()) {
      file.deleteSync();
    }
  }
  stdout.writeln('ok');
}
