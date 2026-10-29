import 'dart:io';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('daravel_wal_'));
  tearDown(() => dir.deleteSync(recursive: true));

  test("reads SQLite's own log: every committed frame, in order", () {
    final path = p.join(dir.path, 'app.sqlite');
    final db = sqlite3.open(path)
      ..execute('PRAGMA journal_mode=WAL')
      ..execute('PRAGMA wal_autocheckpoint=0')
      ..execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    // The database file as it was before the transactions below.
    final before = File(path).readAsBytesSync();
    for (var i = 0; i < 20; i++) {
      db.execute('INSERT INTO t (v) VALUES (?)', ['row $i' * 50]);
    }
    final wal = File('$path-wal').readAsBytesSync();
    final header = WalHeader.parse(wal)!;
    expect(header.pageSize, 4096);

    final read = readWalFrames(
      wal,
      header,
      offset: WalHeader.size,
      checksum1: header.checksum1,
      checksum2: header.checksum2,
    );
    expect(read.frames.where((f) => f.isCommit), hasLength(21));
    expect(read.offset, wal.length);
    expect(read.validEnd, wal.length);

    // Continuing from the middle gives the rest, nothing twice.
    final first = readWalFrames(
      Uint8List.sublistView(wal, 0, WalHeader.size + 3 * header.frameSize),
      header,
      offset: WalHeader.size,
      checksum1: header.checksum1,
      checksum2: header.checksum2,
    );
    final rest = readWalFrames(
      wal,
      header,
      offset: first.offset,
      checksum1: first.checksum1,
      checksum2: first.checksum2,
    );
    expect(first.frames.length + rest.frames.length, read.frames.length);

    // The frames turn the old file into the current database.
    final copy = p.join(dir.path, 'copy.sqlite');
    File(copy).writeAsBytesSync(before);
    applyWalFrames(copy, read.frames, header.pageSize);
    final restored = sqlite3.open(copy);
    expect(restored.select('SELECT count(*) AS n FROM t').first['n'], 20);
    expect(restored.select('PRAGMA integrity_check').first.values.first, 'ok');
    restored.close();
    db.close();
  });

  test('a corrupt or foreign frame ends the read', () {
    final path = p.join(dir.path, 'app.sqlite');
    final db = sqlite3.open(path)
      ..execute('PRAGMA journal_mode=WAL')
      ..execute('PRAGMA wal_autocheckpoint=0')
      ..execute('CREATE TABLE t (v)')
      ..execute('INSERT INTO t VALUES (1)')
      ..execute('INSERT INTO t VALUES (2)');
    final wal = File('$path-wal').readAsBytesSync();
    db.close();
    final header = WalHeader.parse(wal)!;
    final all = readWalFrames(
      wal,
      header,
      offset: 32,
      checksum1: header.checksum1,
      checksum2: header.checksum2,
    );
    // One flipped byte in the second frame's page: it and everything
    // after it are not trusted.
    final broken = Uint8List.fromList(wal);
    broken[32 + header.frameSize + 24 + 100] ^= 0xff;
    final cut = readWalFrames(
      broken,
      header,
      offset: 32,
      checksum1: header.checksum1,
      checksum2: header.checksum2,
    );
    expect(cut.validEnd, 32 + header.frameSize);
    expect(cut.frames.length, lessThan(all.frames.length));
    expect(WalHeader.parse(Uint8List(10)), isNull);
    final badHeader = Uint8List.fromList(wal)..[20] ^= 1;
    expect(WalHeader.parse(badHeader), isNull, reason: 'header checksum');
  });
}
