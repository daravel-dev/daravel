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

  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test('concurrent writes in one isolate each get a temporary file', () async {
    final store = FileStore(p.join(temp.path, 'cache'));
    await Future.wait(<Future<void>>[
      for (var i = 0; i < 200; i++) store.put('same', i),
    ]);
    final values = await Future.wait(<Future<int>>[
      for (var i = 0; i < 200; i++) store.increment('counter'),
    ]);
    expect(values.toSet(), hasLength(200));
    expect(await store.get('counter'), 200);
  });

  test('concurrent writes of one key in one isolate collapse into the '
      'newest instead of racing their renames', () async {
    final store = FileStore(p.join(temp.path, 'cache'));
    final completed = <String>[];
    await Future.wait(<Future<void>>[
      for (var i = 0; i < 200; i++)
        store.put('same', i).then((_) => completed.add('$i')),
    ]);
    // Every caller completes, and the newest value is the one stored.
    expect(completed, hasLength(200));
    expect(await store.get('same'), 199);
    // A write after the queue drained starts on its own.
    await store.put('same', 'last');
    expect(await store.get('same'), 'last');
    final leftovers = Directory(p.join(temp.path, 'cache'))
        .listSync(recursive: true)
        .where((e) => e.path.endsWith('.tmp'));
    expect(leftovers, isEmpty);
  });

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
