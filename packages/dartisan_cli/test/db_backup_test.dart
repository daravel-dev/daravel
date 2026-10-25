import 'dart:async';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late String path;

  DatabaseManager open(String file) => DatabaseManager(
    DatabaseConfig(
      defaultConnection: 'sqlite',
      connections: {
        'sqlite': ConnectionConfig(driver: 'sqlite', database: file),
      },
    ),
  );

  setUp(() async {
    root = Directory.systemTemp.createTempSync('daravel_backup_');
    path = p.join(root.path, 'database.sqlite');
    final db = open(path);
    await db.statement(
      'CREATE TABLE "orders" ("id" INTEGER PRIMARY KEY, "note" TEXT)',
    );
    for (var i = 0; i < 200; i++) {
      await db.table('orders').insert({'note': 'order $i'});
    }
    await db.closeAll();
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('VACUUM INTO makes a checked copy and never overwrites', () async {
    final db = open(path);
    addTearDown(db.closeAll);
    final target = p.join(root.path, 'backups', 'one.sqlite');
    final size = await backupSqlite(db, target);
    expect(size, File(target).lengthSync());
    final copy = open(target);
    addTearDown(copy.closeAll);
    expect(await copy.table('orders').count(), 200);
    await expectLater(backupSqlite(db, target), throwsStateError);
  });

  test(
    'a backup taken while another connection writes is consistent',
    () async {
      final reader = open(path);
      final writer = open(path);
      addTearDown(reader.closeAll);
      addTearDown(writer.closeAll);
      var writing = true;
      var written = 0;
      final load = () async {
        while (writing) {
          await writer.transaction(() async {
            await writer.table('orders').insert({'note': 'a'});
            await writer.table('orders').insert({'note': 'b'});
          });
          written += 2;
          await Future<void>.delayed(Duration.zero);
        }
      }();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      final target = p.join(root.path, 'hot.sqlite');
      await backupSqlite(reader, target);
      writing = false;
      await load;
      expect(written, greaterThan(0), reason: 'writes overlapped the backup');
      final copy = open(target);
      addTearDown(copy.closeAll);
      final rows = await copy.table('orders').count();
      // A snapshot: the seed plus whole transactions (pairs), never half.
      expect(rows, greaterThanOrEqualTo(200));
      expect(rows.isEven, isTrue);
    },
  );

  test('pruneBackups keeps the newest N', () {
    final dir = Directory(p.join(root.path, 'backups'))..createSync();
    for (final day in ['01', '02', '03', '04']) {
      File(p.join(dir.path, 'app-2026-10-$day-020000.sqlite'))
          .writeAsStringSync('x');
    }
    File(p.join(dir.path, 'notes.txt')).writeAsStringSync('x');
    final removed = pruneBackups(dir.path, 2).map(p.basename);
    expect(removed, [
      'app-2026-10-02-020000.sqlite',
      'app-2026-10-01-020000.sqlite',
    ]);
    expect(dir.listSync().map((f) => p.basename(f.path)).toSet(), {
      'app-2026-10-04-020000.sqlite',
      'app-2026-10-03-020000.sqlite',
      'notes.txt',
    });
  });

  test(
    'db:backup writes to storage/backups and refuses other drivers',
    () async {
      Application app(String connection) =>
          Application.configure(basePath: root.path).withEnv({
            'APP_ENV': 'local',
            'DB_CONNECTION': connection,
            'DB_DATABASE': connection == 'sqlite' ? 'database.sqlite' : 'shop',
          }).create();
      final runner = DartisanRunner(() => app('sqlite'));
      final dir = p.join(root.path, 'storage', 'backups');
      expect(await runner.execute(['db:backup']), 0);
      List<String> names() => [
        for (final f in Directory(dir).listSync().whereType<File>())
          p.basename(f.path),
      ];
      expect(names().single, matches(RegExp(r'^database-[\d-]{17}\.sqlite$')));
      // A later name sorts after it; --keep=1 leaves only that one.
      final later = p.join(dir, 'database-9999-12-31-235959.sqlite');
      expect(
        await runner.execute(['db:backup', '--output=$later', '--keep=1']),
        0,
      );
      expect(names(), ['database-9999-12-31-235959.sqlite']);
      // The same name again is refused, not overwritten.
      expect(await runner.execute(['db:backup', '--output=$later']), 1);
      expect(
        await DartisanRunner(() => app('pgsql')).execute(['db:backup']),
        1,
      );
    },
  );
}
