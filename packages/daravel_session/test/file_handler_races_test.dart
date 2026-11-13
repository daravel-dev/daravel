import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:daravel_session/daravel_session.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Sweeps in another isolate until [stop] is set (a file in the directory).
Future<void> _sweep(String directory) async {
  final handler = FileSessionHandler(directory, lifetime: Duration.zero);
  final stop = File(p.join(directory, '.stop'));
  while (!stop.existsSync()) {
    await handler.gc(Duration.zero);
  }
}

/// SG-1: the file driver's `read` and `destroy` race the sweep of another
/// isolate (or process, or Laravel's) without failing the request; the
/// sweep leaves dotfiles alone; `gcBatch` must be at least 1.
void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('daravel_session_races_');
  });

  tearDown(() async {
    for (var i = 0; i < 50; i++) {
      try {
        dir.deleteSync(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
    }
  });

  test('read and destroy while another isolate sweeps: no error, 1 500 '
      'rounds', () async {
    final handler = FileSessionHandler(
      dir.path,
      lifetime: const Duration(hours: 2),
    );
    final sweeper = Isolate.run(() => _sweep(dir.path));
    final errors = <Object>[];
    for (var i = 0; i < 1500; i++) {
      final id = 'session${i % 20}';
      try {
        await handler.write(id, 'a:0:{}');
        await handler.read(id);
        await handler.destroy(id);
      } on Object catch (error) {
        errors.add(error);
      }
    }
    File(p.join(dir.path, '.stop')).writeAsStringSync('');
    await sweeper;
    expect(errors, isEmpty, reason: '${errors.take(3)}');
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('a missing session reads as null and destroys quietly', () async {
    final handler = FileSessionHandler(
      dir.path,
      lifetime: const Duration(hours: 2),
    );
    expect(await handler.read('missing'), isNull);
    await handler.destroy('missing');
  });

  test('the sweep leaves dotfiles alone, as Laravel ignores them', () async {
    final keep = File(p.join(dir.path, '.gitignore'))..writeAsStringSync('*');
    final session = File(p.join(dir.path, 'old'))..writeAsStringSync('a:0:{}');
    final past = DateTime.now().subtract(const Duration(days: 2));
    keep.setLastModifiedSync(past);
    session.setLastModifiedSync(past);
    final handler = FileSessionHandler(
      dir.path,
      lifetime: const Duration(hours: 2),
    );
    await handler.gc(const Duration(hours: 2));
    expect(keep.existsSync(), isTrue);
    expect(session.existsSync(), isFalse);
  });

  test('gcBatch below 1 is refused', () {
    expect(
      () => FileSessionHandler(dir.path, lifetime: Duration.zero, gcBatch: 0),
      throwsA(isA<ArgumentError>()),
    );
  });
}
