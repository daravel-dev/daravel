import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

LogRecord record(DateTime time, String message) => LogRecord(
  time: time,
  level: LogLevel.info,
  message: message,
  channel: 'daily',
);

List<String> messagesIn(File file) => [
  for (final line in file.readAsLinesSync())
    (jsonDecode(line) as Map<String, Object?>)['message']! as String,
];

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('daravel_log_output_');
  });
  tearDown(() async {
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  });

  group('DailyFileHandler', () {
    test('a file that cannot be opened is no uncaught error, and later lines '
        'land once it can be', () async {
      final day = DateTime.utc(2026, 11, 6, 12);
      final handler = DailyFileHandler(dir.path, retryAfter: Duration.zero);
      final path = handler.pathFor(day);
      // A directory where the file should be: opening it fails (EISDIR on
      // Linux and macOS, access denied on Windows).
      Directory(path).createSync();
      final errors = <Object>[];
      await runZonedGuarded(() async {
        for (var i = 0; i < 5; i++) {
          handler.handle(record(day, 'lost $i'));
        }
        await handler.flush();
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
      expect(handler.dropped, 5);
      expect(handler.pendingBytes, 0);

      Directory(path).deleteSync();
      await runZonedGuarded(() async {
        handler
          ..handle(record(day, 'kept 1'))
          ..handle(record(day, 'kept 2'));
        await handler.close();
      }, (error, _) => errors.add(error));
      expect(errors, isEmpty);
      expect(messagesIn(File(path)), ['kept 1', 'kept 2']);
    });

    test('memory waiting for the disk is bounded: lines past the limit are '
        'dropped and counted', () async {
      const limit = 64 * 1024;
      final handler = DailyFileHandler(dir.path, maxPendingBytes: limit);
      final day = DateTime.utc(2026, 11, 6);
      final before = LogLineQueue.droppedTotal;
      var peak = 0;
      const lines = 20000;
      for (var i = 0; i < lines; i++) {
        handler.handle(record(day, 'line $i'));
        if (handler.pendingBytes > peak) {
          peak = handler.pendingBytes;
        }
      }
      expect(peak, lessThanOrEqualTo(limit));
      expect(handler.dropped, greaterThan(0));
      expect(LogLineQueue.droppedTotal - before, handler.dropped);
      await handler.close();
      final written = messagesIn(File(handler.pathFor(day)));
      expect(written, hasLength(lines - handler.dropped));
      // What was kept is in order and starts at the first line.
      expect(written.first, 'line 0');
    });

    test('rotation writes every line of the previous day before close '
        'returns', () async {
      final handler = DailyFileHandler(dir.path, days: 0);
      final first = DateTime.utc(2026, 11, 5, 23, 59);
      final second = DateTime.utc(2026, 11, 6, 0, 1);
      for (var i = 0; i < 1000; i++) {
        handler.handle(record(first, 'a$i'));
      }
      handler.handle(record(second, 'b0'));
      await handler.close();
      expect(messagesIn(File(handler.pathFor(first))), hasLength(1000));
      expect(messagesIn(File(handler.pathFor(second))), ['b0']);
      expect(handler.dropped, 0);
    });
  });

  test('LogLineQueue keeps order per target and flushes', () async {
    final written = <(Object?, String)>[];
    final queue = LogLineQueue((bytes, target) async {
      written.add((target, utf8.decode(bytes)));
    });
    queue
      ..add('a', target: 'x')
      ..add('b', target: 'x')
      ..add('c', target: 'y');
    expect(queue.isIdle, isFalse);
    await queue.flush();
    expect(queue.isIdle, isTrue);
    // Batches never mix targets; how lines are batched is up to the loop.
    expect(written.map((w) => w.$2).join(), 'a\nb\nc\n');
    expect(written.where((w) => w.$1 == 'y').map((w) => w.$2), ['c\n']);
  });

  test('a failing writer drops its lines without an uncaught error', () async {
    final errors = <Object>[];
    late LogLineQueue queue;
    await runZonedGuarded(() async {
      queue = LogLineQueue((_, _) => Future<void>.error(StateError('disk')));
      queue
        ..add('a')
        ..add('b');
      await queue.flush();
    }, (error, _) => errors.add(error));
    expect(errors, isEmpty);
    expect(queue.dropped, 2);
    expect(queue.pendingBytes, 0);
  });

  test('the console handler never blocks on a stdout nobody reads', () async {
    const lines = 20000;
    final child = await Process.start(Platform.resolvedExecutable, [
      p.join('test', 'logging', 'console_flood_main.dart'),
      '$lines',
    ]);
    // stdout is not read until the child says logging returned: with a
    // blocking write the pipe fills after a few KB and the child hangs.
    final stderrLines = child.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .asBroadcastStream();
    final logged = await stderrLines
        .firstWhere((line) => line.startsWith('logged '))
        .timeout(const Duration(seconds: 60));
    expect(logged, 'logged 0');
    final out = await child.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .where((line) => line.contains('[INFO] line '))
        .length;
    expect(await child.exitCode, 0);
    expect(out, lines);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
