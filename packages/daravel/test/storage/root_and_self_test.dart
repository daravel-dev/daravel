import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// What the shared disk contract (`daravel_s3`'s `disk_contract.dart`)
/// cannot see: files left beside a local disk, and a read-through disk's
/// fallback.
void main() {
  late Directory parent;
  late LocalDisk disk;

  setUp(() {
    parent = Directory.systemTemp.createTempSync('root_self_');
    disk = LocalDisk('local', p.join(parent.path, 'root'));
  });
  tearDown(() => parent.deleteSync(recursive: true));

  List<String> beside() =>
      [for (final entity in parent.listSync()) p.basename(entity.path)]..sort();

  test("put('.') writes nothing, not even beside the root", () async {
    await disk.put('kept.txt', 'kept');
    for (final path in ['', '.', 'sub/..']) {
      await expectLater(
        disk.put(path, 'x'),
        throwsA(isA<StorageException>()),
        reason: '"$path"',
      );
    }
    // Before, `<root>.<µs>.tmp` was left next to the root.
    expect(beside(), ['root']);
    expect(await disk.allFiles(), ['kept.txt']);
  });

  test('a put that cannot rename leaves no .tmp', () async {
    await disk.makeDirectory('taken');
    // A directory is where the file would go: the rename fails.
    await expectLater(disk.put('taken', 'x'), throwsA(isA<Exception>()));
    expect(Directory(disk.root).listSync().map((e) => p.basename(e.path)), [
      'taken',
    ]);
  });

  test('ReadThroughDisk: moving a file onto itself keeps it on the '
      'fallback, and does not promote it', () async {
    final primary = MemoryDisk('primary');
    final fallback = MemoryDisk('fallback');
    final both = ReadThroughDisk(primary: primary, fallback: fallback);
    await fallback.put('old.txt', 'only there');
    await both.move('old.txt', 'old.txt');
    await both.copy('old.txt', './old.txt');
    expect(await fallback.get('old.txt'), 'only there');
    expect(await primary.exists('old.txt'), isFalse);
    await primary.put('two.txt', 'p');
    await fallback.put('two.txt', 'f');
    await both.move('two.txt', 'two.txt');
    expect(await primary.get('two.txt'), 'p');
    expect(await fallback.get('two.txt'), 'f');
  });
}
