import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('db_replicate_'));
  tearDown(() => dir.deleteSync(recursive: true));

  Application createApp() => Application.configure(basePath: dir.path).withEnv({
    'APP_ENV': 'local',
    'DB_DATABASE': 'database/app.sqlite',
    'LOG_LEVEL': 'emergency',
  }).create();

  Future<int?> dartisan(List<String> args) =>
      DartisanRunner(createApp).run(args);

  int count(String path) {
    final db = sqlite3.open(path);
    try {
      return db.select('SELECT count(*) AS n FROM notes').first['n'] as int;
    } finally {
      db.close();
    }
  }

  test('db:replicate, db:replicas and db:restore on the local disk', () async {
    final path = p.join(dir.path, 'database', 'app.sqlite');
    Directory(p.dirname(path)).createSync(recursive: true);
    final app = sqlite3.open(path)
      ..execute('PRAGMA journal_mode=WAL')
      ..execute('CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT)');
    for (var i = 0; i < 30; i++) {
      app.execute('INSERT INTO notes (body) VALUES (?)', ['note $i']);
    }
    expect(await dartisan(['db:replicate', '--once', '--disk=local']), 0);
    for (var i = 0; i < 20; i++) {
      app.execute('INSERT INTO notes (body) VALUES (?)', ['later $i']);
    }
    // A second run is a new process: it starts its own generation.
    expect(await dartisan(['db:replicate', '--once', '--disk=local']), 0);
    app.close();

    expect(await dartisan(['db:replicas', '--disk=local']), 0);

    final restored = p.join(dir.path, 'restored.sqlite');
    expect(await dartisan(['db:restore', '--disk=local', '--to=$restored']), 0);
    expect(count(restored), 50);
    expect(
      await dartisan(['db:restore', '--disk=local', '--to=$restored']),
      1,
      reason: 'never overwrites without --force',
    );
    expect(await dartisan(['db:restore', '--disk=local', '--if-missing']), 0);
  });

  test('a database not in WAL mode is refused', () async {
    final path = p.join(dir.path, 'database', 'app.sqlite');
    Directory(p.dirname(path)).createSync(recursive: true);
    sqlite3.open(path)
      ..execute('CREATE TABLE notes (id INTEGER PRIMARY KEY)')
      ..close();
    await expectLater(
      dartisan(['db:replicate', '--once', '--disk=local']),
      throwsA(isA<ReplicationException>()),
    );
  });
}
