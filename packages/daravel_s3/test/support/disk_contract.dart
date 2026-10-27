import 'dart:convert';
import 'dart:typed_data';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// The behaviour every [Disk] shares, run against `MemoryDisk` and
/// `LocalDisk` (the reference) and against `S3Disk`, so the S3 disk is
/// held to what the core disks do rather than to its own idea of it.
///
/// [refusesRootDelete] is off for `MemoryDisk` only: unlike `LocalDisk` it
/// answers `deleteDirectory('')` with `false` instead of refusing.
void diskContract(
  Future<Disk> Function() create, {
  bool refusesRootDelete = true,
}) {
  late Disk disk;

  setUp(() async => disk = await create());

  test('put and get round-trip strings and every byte value', () async {
    await disk.put('notes/hello.txt', 'Halo, Bali 🌴');
    expect(await disk.get('notes/hello.txt'), 'Halo, Bali 🌴');

    final bytes = Uint8List.fromList(List.generate(256, (i) => i));
    await disk.put('bin/all.bytes', bytes);
    expect(await disk.getBytes('bin/all.bytes'), bytes);
    expect(await disk.size('bin/all.bytes'), 256);
  });

  test('put overwrites', () async {
    await disk.put('a.txt', 'one');
    await disk.put('a.txt', 'two');
    expect(await disk.get('a.txt'), 'two');
  });

  test('exists, missing and reading a missing file', () async {
    await disk.put('here.txt', 'x');
    expect(await disk.exists('here.txt'), isTrue);
    expect(await disk.missing('gone.txt'), isTrue);
    await expectLater(disk.get('gone.txt'), throwsA(isA<StorageException>()));
    await expectLater(
      disk.readStream('gone.txt').toList(),
      throwsA(isA<StorageException>()),
    );
    await expectLater(disk.size('gone.txt'), throwsA(isA<StorageException>()));
  });

  test('putStream and readStream move the same bytes', () async {
    final chunks = [
      for (var i = 0; i < 40; i++)
        List<int>.generate(997, (j) => (i + j) % 256),
    ];
    await disk.putStream('big/file.bin', Stream.fromIterable(chunks));
    final read = BytesBuilder();
    await disk.readStream('big/file.bin').forEach(read.add);
    expect(read.takeBytes(), chunks.expand((c) => c).toList());
  });

  test('append adds lines', () async {
    await disk.append('log.txt', 'first');
    await disk.append('log.txt', 'second');
    expect(await disk.get('log.txt'), 'first\nsecond');
  });

  test('delete says whether every file existed', () async {
    await disk.put('d/1.txt', '1');
    await disk.put('d/2.txt', '2');
    expect(await disk.delete('d/1.txt'), isTrue);
    expect(await disk.delete(['d/2.txt', 'd/none.txt']), isFalse);
    expect(await disk.exists('d/2.txt'), isFalse);
    expect(await disk.delete('d/none.txt'), isFalse);
  });

  test('copy and move', () async {
    await disk.put('src.txt', 'payload');
    await disk.copy('src.txt', 'copies/dst.txt');
    expect(await disk.get('copies/dst.txt'), 'payload');
    expect(await disk.exists('src.txt'), isTrue);

    await disk.move('src.txt', 'moved/src.txt');
    expect(await disk.exists('src.txt'), isFalse);
    expect(await disk.get('moved/src.txt'), 'payload');

    await expectLater(
      disk.copy('none.txt', 'x.txt'),
      throwsA(isA<StorageException>()),
    );
  });

  test('lastModified is a recent UTC time', () async {
    await disk.put('t.txt', 't');
    final modified = await disk.lastModified('t.txt');
    expect(modified.isUtc, isTrue);
    expect(
      DateTime.now().toUtc().difference(modified).inSeconds.abs(),
      lessThan(120),
    );
  });

  group('listing', () {
    setUp(() async {
      for (final path in [
        'a.txt',
        'dir/b.txt',
        'dir/sub/c.txt',
        'dir/sub/deep/d.txt',
        'other/e.txt',
      ]) {
        await disk.put(path, path);
      }
    });

    test('files and allFiles', () async {
      expect(await disk.files(), ['a.txt']);
      expect(await disk.files('dir'), ['dir/b.txt']);
      expect(await disk.allFiles('dir'), [
        'dir/b.txt',
        'dir/sub/c.txt',
        'dir/sub/deep/d.txt',
      ]);
      expect(await disk.allFiles(), hasLength(5));
      expect(await disk.files('nothing'), isEmpty);
    });

    test('directories', () async {
      expect(await disk.directories(), ['dir', 'other']);
      expect(await disk.directories('dir'), ['dir/sub']);
      expect(await disk.directories('dir', true), ['dir/sub', 'dir/sub/deep']);
    });

    test('makeDirectory shows in directories, not in files', () async {
      await disk.makeDirectory('empty/inner');
      expect(await disk.directories('empty'), ['empty/inner']);
      expect(await disk.allFiles('empty'), isEmpty);
    });

    test('deleteDirectory removes everything below', () async {
      expect(await disk.deleteDirectory('dir'), isTrue);
      expect(await disk.allFiles(), ['a.txt', 'other/e.txt']);
      expect(await disk.deleteDirectory('dir'), isFalse);
      if (refusesRootDelete) {
        await expectLater(
          disk.deleteDirectory(''),
          throwsA(isA<StorageException>()),
        );
      }
    });
  });

  test('keys with spaces, unicode and reserved characters', () async {
    const path = r'odd names/ü + $&=(1)!.txt';
    await disk.put(path, utf8.encode('ok'));
    expect(await disk.get(path), 'ok');
    expect(await disk.files('odd names'), [path]);
    await disk.copy(path, 'odd names/copy of ü.txt');
    expect(await disk.exists('odd names/copy of ü.txt'), isTrue);
  });

  test('paths cannot escape the disk', () async {
    await expectLater(
      disk.put('../outside.txt', 'x'),
      throwsA(isA<StorageException>()),
    );
    await expectLater(
      disk.get('/etc/passwd'),
      throwsA(isA<StorageException>()),
    );
  });
}
