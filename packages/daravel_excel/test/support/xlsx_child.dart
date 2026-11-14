import 'dart:io';

import 'package:daravel_excel/daravel_excel.dart';

/// Reads the workbook at the path given, in a process of its own so a test
/// can bound its time and memory, and prints one line (`ok ROWS LONGEST`
/// or `error TYPE`), then `rss PEAK_BYTES`.
Future<void> main(List<String> args) async {
  try {
    final sheets = await Excel.toArray(
      File(args.single).readAsBytesSync(),
      type: ExcelType.xlsx,
    );
    final rows = sheets.first;
    var longest = 0;
    for (final row in rows) {
      if (row.length > longest) {
        longest = row.length;
      }
    }
    stdout.writeln('ok ${rows.length} $longest');
  } on Object catch (error) {
    stdout.writeln('error ${error.runtimeType}');
  }
  stdout.writeln('rss ${ProcessInfo.maxRss}');
}
