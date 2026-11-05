import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `dart test` runs test files in processes of their own that share
/// `storage/framework/cache`: a FileStore must not lose an increment, or fail
/// a write, because another process wrote, removed or flushed the same file
/// at the same time (daravel-feedback 024).
void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('daravel_file_store_');
  });

  tearDown(() => _deleteDirectory(temp));

  // 400 file operations: a loaded Windows runner (Defender scans every new
  // file) took more than the default 30 s for them.
  test(
    'concurrent writes in one isolate each get a temporary file',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      final store = FileStore(p.join(temp.path, 'cache'));
      await Future.wait(<Future<void>>[
        for (var i = 0; i < 200; i++) store.put('same', i),
      ]);
      final values = await Future.wait(<Future<int>>[
        for (var i = 0; i < 200; i++) store.increment('counter'),
      ]);
      expect(values.toSet(), hasLength(200));
      expect(await store.get('counter'), 200);
    },
  );

  test('a flush while writing does not fail the write', () async {
    final store = FileStore(p.join(temp.path, 'cache'));
    await Future.wait(<Future<void>>[
      for (var i = 0; i < 100; i++) ...[store.put('k$i', i), store.flush()],
    ]);
  });

  test(
    'processes sharing the directory lose no increment and no write fails',
    timeout: const Timeout(Duration(minutes: 3)),
    () async {
      final kernel = p.join(temp.path, 'worker.dill');
      final compiled = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'kernel',
        p.join('test', 'cache', 'fixtures', 'file_store_worker.dart'),
        '-o',
        kernel,
      ]);
      expect(compiled.exitCode, 0, reason: '${compiled.stderr}');
      final cache = p.join(temp.path, 'cache');
      const processes = 4;
      const rounds = 150;
      final results = await Future.wait([
        for (var i = 0; i < processes; i++)
          Process.run(Platform.resolvedExecutable, [
            kernel,
            cache,
            '$rounds',
            'w$i',
          ]),
      ]);
      for (final result in results) {
        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
      }
      final store = FileStore(cache);
      expect(await store.get('counter'), processes * rounds);
      expect(await store.get('added'), isNotNull);
      final leftovers = Directory(cache)
          .listSync(recursive: true)
          .where((e) => e.path.endsWith('.tmp'));
      expect(leftovers, isEmpty);
    },
  );
}

/// Deletes [directory], trying again for a while: Windows refuses to delete
/// a file another handle still has open (errno 32), such as a virus scanner
/// on a file just written, or the operations of a test that timed out.
Future<void> _deleteDirectory(Directory directory) async {
  final waited = Stopwatch()..start();
  while (true) {
    try {
      if (await directory.exists()) {
        await directory.delete(recursive: true);
      }
      return;
    } on FileSystemException {
      if (waited.elapsed > const Duration(seconds: 10)) {
        rethrow;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
}
