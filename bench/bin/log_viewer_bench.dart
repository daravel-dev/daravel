// Blueprint #53's stress test: the newest 50 entries of 100 MB and 500 MB
// log files, and a filtered page that scans the whole 64 MB limit. Each
// size runs in a fresh process, so the peak memory is that read's.
//
//   dart run bench/bin/log_viewer_bench.dart            # 100 MB and 500 MB
//   dart run bench/bin/log_viewer_bench.dart 100        # one run
import 'dart:convert';
import 'dart:io';

import 'package:daravel_log_viewer/daravel_log_viewer.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stdout.writeln(
      '| file | newest 50 | filtered page (64 MB scan) | peak RSS |',
    );
    stdout.writeln('| --: | --: | --: | --: |');
    for (final mb in [100, 500]) {
      final result = await Process.run(Platform.resolvedExecutable, [
        if (!Platform.resolvedExecutable.endsWith('log_viewer_bench.exe') &&
            !Platform.resolvedExecutable.endsWith('log_viewer_bench')) ...[
          'run',
          Platform.script.toFilePath(),
        ],
        '$mb',
      ]);
      stdout.write(result.stdout);
      stderr.write(result.stderr);
    }
    return;
  }
  if (args.first == 'generate') {
    await _generate(int.parse(args[1]));
    return;
  }
  final megabytes = int.parse(args.first);
  final file = _file(megabytes);
  if (!file.existsSync() || file.lengthSync() < megabytes * 1024 * 1024) {
    // Written by another process, so this one's peak memory is the read's.
    final self = Platform.resolvedExecutable;
    await Process.run(self, [
      if (!self.contains('log_viewer_bench')) ...[
        'run',
        Platform.script.toFilePath(),
      ],
      'generate',
      '$megabytes',
    ]);
  }
  final reader = ReverseLogReader(file.path);
  await reader.page(limit: 50); // warm the file cache
  final newest = Stopwatch()..start();
  final page = await reader.page(limit: 50);
  newest.stop();
  final filtered = Stopwatch()..start();
  await reader.page(limit: 50, filter: const LogFilter(search: 'no such text'));
  filtered.stop();
  if (page.entries.length != 50) {
    throw StateError('expected 50 entries');
  }
  stdout.writeln(
    '| $megabytes MB | ${(newest.elapsedMicroseconds / 1000).toStringAsFixed(2)} ms | '
    '${filtered.elapsedMilliseconds} ms | '
    '${(ProcessInfo.maxRss / 1024 / 1024).toStringAsFixed(0)} MB |',
  );
}

File _file(int megabytes) =>
    File('${Directory.systemTemp.path}/daravel_log_bench_$megabytes.log');

Future<void> _generate(int megabytes) async {
  final sink = _file(megabytes).openWrite();
  var written = 0;
  var i = 0;
  while (written < megabytes * 1024 * 1024) {
    final line =
        '${jsonEncode({
          'time': '2026-10-28T08:00:00.000Z',
          'level': i % 1000 == 0 ? 'error' : 'info',
          'channel': 'app',
          'message': 'request $i handled',
          'context': {'request_id': 'r-$i', 'user_id': i % 97},
        })}\n';
    sink.write(line);
    if (i % 10000 == 0) {
      await sink.flush();
    }
    written += line.length;
    i++;
  }
  await sink.close();
}
