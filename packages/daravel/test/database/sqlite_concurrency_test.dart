import 'dart:io';
import 'dart:isolate';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Opens the file database and writes, as a worker isolate does at boot.
Future<int> _writer((String path, int id) args) async {
  final driver = SqliteDriver(path: args.$1);
  await driver.connect();
  try {
    await driver.execute(
      'CREATE TABLE IF NOT EXISTS hits ("id" INTEGER PRIMARY KEY, "worker" INTEGER)',
    );
    for (var i = 0; i < 20; i++) {
      await driver.execute('INSERT INTO hits ("worker") VALUES (?)', [args.$2]);
    }
    return 0;
  } finally {
    await driver.close();
  }
}

void main() {
  test(
    'isolates opening one new WAL file at once wait instead of failing',
    () async {
      final dir = Directory.systemTemp.createTempSync('daravel_sqlite_busy');
      addTearDown(() => dir.deleteSync(recursive: true));
      final path = p.join(dir.path, 'shared.sqlite');
      final results = await Future.wait([
        for (var id = 0; id < 8; id++) Isolate.run(() => _writer((path, id))),
      ]);
      expect(results, everyElement(0));
      final check = SqliteDriver(path: path);
      await check.connect();
      addTearDown(check.close);
      final rows = await check.select('SELECT COUNT(*) AS c FROM hits');
      expect(rows.single['c'], 160);
    },
  );
}
