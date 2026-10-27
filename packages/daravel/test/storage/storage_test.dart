import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('normalizeDiskPath rejects traversal and absolute paths', () {
    expect(normalizeDiskPath('a/./b/../c.txt'), 'a/c.txt');
    expect(normalizeDiskPath(r'a\b.txt'), 'a/b.txt');
    expect(normalizeDiskPath(''), '');
    for (final bad in [
      '../x',
      'a/../../x',
      '/etc/passwd',
      r'C:\Windows',
      '..',
    ]) {
      expect(
        () => normalizeDiskPath(bad),
        throwsA(isA<StorageException>()),
        reason: bad,
      );
    }
  });

  group('LocalDisk', () {
    late Directory root;
    late LocalDisk disk;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('daravel_disk_');
      disk = LocalDisk(
        'local',
        root.path,
        baseUrl: 'https://cdn.test/storage/',
      );
    });

    tearDown(() => root.delete(recursive: true));

    test('put/get/append/copy/move/delete/size/lastModified', () async {
      await disk.put('docs/readme.txt', 'hello');
      await disk.put('bin/data.bin', [1, 2, 3]);
      expect(await disk.get('docs/readme.txt'), 'hello');
      expect(await disk.getBytes('bin/data.bin'), [1, 2, 3]);
      await disk.append('docs/readme.txt', 'world');
      expect(await disk.get('docs/readme.txt'), 'hello\nworld');
      expect(await disk.size('bin/data.bin'), 3);
      expect(
        (await disk.lastModified('bin/data.bin')).isAfter(DateTime.utc(2020)),
        isTrue,
      );
      await disk.copy('docs/readme.txt', 'copy/readme.txt');
      await disk.move('copy/readme.txt', 'moved/readme.txt');
      expect(await disk.exists('copy/readme.txt'), isFalse);
      expect(await disk.exists('moved/readme.txt'), isTrue);
      await disk.putStream(
        'stream.txt',
        Stream.fromIterable([utf8.encode('ab'), utf8.encode('c')]),
      );
      expect(await utf8.decodeStream(disk.readStream('stream.txt')), 'abc');
      expect(await disk.delete(['stream.txt', 'nope.txt']), isFalse);
      expect(await disk.missing('stream.txt'), isTrue);
      expect(() => disk.get('nope.txt'), throwsA(isA<StorageException>()));
      expect(
        File(p.join(root.path, 'docs', 'readme.txt')).existsSync(),
        isTrue,
      );
    });

    test('listing, directories, urls and traversal guard', () async {
      await disk.put('a/1.txt', '1');
      await disk.put('a/b/2.txt', '2');
      await disk.put('top.txt', 't');
      expect(await disk.files(), ['top.txt']);
      expect(await disk.files('a'), ['a/1.txt']);
      expect(await disk.allFiles('a'), ['a/1.txt', 'a/b/2.txt']);
      expect(await disk.directories(), ['a']);
      expect(await disk.directories('', true), ['a', 'a/b']);
      expect(
        disk.url('a/my file.txt'),
        'https://cdn.test/storage/a/my%20file.txt',
      );
      expect(
        () => disk.put('../escape.txt', 'x'),
        throwsA(isA<StorageException>()),
      );
      expect(() => disk.deleteDirectory(''), throwsA(isA<StorageException>()));
      expect(await disk.deleteDirectory('a'), isTrue);
      expect(await disk.allFiles(), ['top.txt']);
      expect(
        () => LocalDisk('private', root.path).url('x'),
        throwsA(isA<StorageException>()),
      );
    });
  });

  test('MemoryDisk mirrors the API and offers assertions', () async {
    final disk = MemoryDisk('avatars', baseUrl: '/storage/avatars');
    await disk.put('u/1.png', [9]);
    await disk.put('u/2/thumb.png', [8]);
    await disk.makeDirectory('empty');
    disk.assertExists(['u/1.png', 'u/2/thumb.png']);
    disk.assertMissing('u/3.png');
    expect(await disk.files('u'), ['u/1.png']);
    expect(await disk.directories(), ['empty', 'u']);
    expect(disk.url('u/1.png'), '/storage/avatars/u/1.png');
    await disk.append('log.txt', 'a');
    await disk.append('log.txt', 'b');
    disk.assertExists('log.txt', 'a\nb');
    expect(() => disk.assertExists('u/3.png'), throwsStateError);
    expect(await disk.deleteDirectory('u'), isTrue);
    disk.assertDirectoryEmpty('u');
    // As LocalDisk: a fake must not accept what the real disk refuses.
    await expectLater(
      disk.deleteDirectory(''),
      throwsA(isA<StorageException>()),
    );
    await expectLater(
      disk.deleteDirectory('./'),
      throwsA(isA<StorageException>()),
    );
    disk.assertExists('log.txt');
  });

  test('manager, facade fake and storage:link', () async {
    final base = await Directory.systemTemp.createTemp('daravel_app_');
    addTearDown(() => base.delete(recursive: true));
    final app = Application.configure(basePath: base.path).withEnv({
      'APP_ENV': 'testing',
      'DB_DATABASE': ':memory:',
      'APP_URL': 'https://example.test',
    }).create();
    await app.boot();
    addTearDown(app.shutdown);
    await app.run(() async {
      await Storage.put('private.txt', 'secret');
      expect(
        File(p.join(base.path, 'storage', 'app', 'private', 'private.txt'))
            .existsSync(),
        isTrue,
      );
      await Storage.disk('public').put('avatars/a.png', [1]);
      expect(
        Storage.disk('public').url('avatars/a.png'),
        'https://example.test/storage/avatars/a.png',
      );
      expect(() => Storage.disk('s3'), throwsA(isA<ConfigException>()));

      final fake = Storage.fake('public');
      await Storage.disk('public').put('x.txt', 'y');
      fake.assertExists('x.txt', 'y');
      expect(
        File(p.join(base.path, 'storage', 'app', 'public', 'x.txt'))
            .existsSync(),
        isFalse,
      );

      try {
        final created = await Storage.manager.link();
        expect(created, ['public/storage']);
        expect(
          await Link(p.join(base.path, 'public', 'storage')).exists(),
          isTrue,
        );
        expect(await Storage.manager.link(), isEmpty);
      } on FileSystemException catch (e) {
        // Windows without Developer Mode cannot create symlinks.
        markTestSkipped('Symlinks unavailable: ${e.message}');
      }
    });
  });
}
