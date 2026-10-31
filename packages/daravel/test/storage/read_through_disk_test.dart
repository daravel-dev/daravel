import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  late MemoryDisk primary;
  late MemoryDisk fallback;
  late ReadThroughDisk disk;

  setUp(() async {
    primary = MemoryDisk('new');
    fallback = MemoryDisk('old');
    disk = ReadThroughDisk(primary: primary, fallback: fallback);
    await fallback.put('old.txt', 'from the old disk');
  });

  test('a read falls back, then the file is on the primary', () async {
    expect(await disk.get('old.txt'), 'from the old disk');
    expect(await primary.get('old.txt'), 'from the old disk');
  });

  test('bytes and streams promote too', () async {
    expect(utf8.decode(await disk.getBytes('old.txt')), 'from the old disk');
    await fallback.put('s.txt', 'stream');
    final bytes = await disk.readStream('s.txt').expand((c) => c).toList();
    expect(utf8.decode(bytes), 'stream');
    expect(await primary.exists('s.txt'), isTrue);
  });

  test('the primary wins', () async {
    await primary.put('old.txt', 'newer');
    expect(await disk.get('old.txt'), 'newer');
    expect(await fallback.get('old.txt'), 'from the old disk');
  });

  test('without promotion the primary stays empty', () async {
    final plain = ReadThroughDisk(
      primary: primary,
      fallback: fallback,
      promote: false,
    );
    expect(await plain.get('old.txt'), 'from the old disk');
    expect(await primary.exists('old.txt'), isFalse);
  });

  test('existence and metadata see both disks', () async {
    expect(await disk.exists('old.txt'), isTrue);
    expect(await disk.missing('nope.txt'), isTrue);
    expect(await disk.size('old.txt'), 17);
    expect(await primary.exists('old.txt'), isFalse, reason: 'no read yet');
  });

  test('writes go to the primary only', () async {
    await disk.put('new.txt', 'x');
    expect(await primary.exists('new.txt'), isTrue);
    expect(await fallback.exists('new.txt'), isFalse);
  });

  test('a deleted file does not come back from the fallback', () async {
    await disk.get('old.txt');
    expect(await disk.delete('old.txt'), isTrue);
    expect(await disk.exists('old.txt'), isFalse);
    expect(await disk.delete('nope.txt'), isFalse);
  });

  test('delete takes a list', () async {
    await primary.put('a.txt', 'a');
    expect(await disk.delete(['a.txt', 'old.txt']), isTrue);
    expect(await disk.exists('a.txt'), isFalse);
    expect(await disk.exists('old.txt'), isFalse);
  });

  test('move leaves nothing on the fallback', () async {
    await disk.move('old.txt', 'moved.txt');
    expect(await disk.exists('old.txt'), isFalse);
    expect(await primary.get('moved.txt'), 'from the old disk');
  });

  test('copy and append reach a file still on the fallback', () async {
    await disk.copy('old.txt', 'copy.txt');
    expect(await primary.get('copy.txt'), 'from the old disk');
    await fallback.put('log.txt', 'one');
    await disk.append('log.txt', 'two');
    expect(await primary.get('log.txt'), contains('two'));
    expect(await primary.get('log.txt'), startsWith('one'));
  });

  test('a read of a file on neither disk fails', () {
    expect(disk.get('nope.txt'), throwsA(isA<StorageException>()));
  });
}
