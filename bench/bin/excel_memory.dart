// Blueprint #39's benchmark: the memory an export uses as its row count
// grows. Each run is a fresh process, so the peak RSS is that export's.
//
//   dart run bench/bin/excel_memory.dart                  # 10k, 100k, 500k rows
//   dart run bench/bin/excel_memory.dart 100000 xlsx      # one run
import 'dart:io';

import 'package:daravel_excel/daravel_excel.dart';

/// 10 columns of mixed types, generated row by row (no database).
final class Rows implements FromGenerator, WithHeadings {
  Rows(this.count);
  final int count;

  @override
  List<Object?> headings() => [for (var c = 1; c <= 10; c++) 'Kolom $c'];

  @override
  Stream<Object?> generator() async* {
    for (var i = 1; i <= count; i++) {
      yield [
        i,
        'Nama siswa nomor $i',
        'nisn${100000 + i}',
        i * 1.5,
        i.isEven,
        DateTime.utc(2026, 1, 1).add(Duration(minutes: i)),
        'Kelas ${i % 12 + 1}',
        i % 100,
        'Catatan panjang untuk baris $i dengan teks yang cukup panjang',
        null,
      ];
    }
  }
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    final dart = Platform.resolvedExecutable;
    stdout.writeln('| rows | type | file | time | peak RSS |');
    stdout.writeln('| --: | :-- | --: | --: | --: |');
    for (final count in [10000, 100000, 500000]) {
      for (final type in ['xlsx', 'csv']) {
        final result = await Process.run(dart, [
          'run',
          Platform.script.toFilePath(),
          '$count',
          type,
        ]);
        stdout.write(result.stdout);
        stderr.write(result.stderr);
      }
    }
    return;
  }
  final count = int.parse(args[0]);
  final type = args[1] == 'csv' ? ExcelType.csv : ExcelType.xlsx;
  final out = File(
    '${Directory.systemTemp.path}/daravel_excel_bench.${type.name}',
  );
  final watch = Stopwatch()..start();
  final sink = out.openWrite();
  await sink.addStream(Excel.stream(Rows(count), type));
  await sink.close();
  watch.stop();
  final size = out.lengthSync();
  out.deleteSync();
  stdout.writeln(
    '| ${count.toString()} | ${type.name} | '
    '${(size / 1024 / 1024).toStringAsFixed(1)} MB | '
    '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(1)} s | '
    '${(ProcessInfo.maxRss / 1024 / 1024).toStringAsFixed(0)} MB |',
  );
}
