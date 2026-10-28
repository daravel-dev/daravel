// The Daravel side of bench/interop/excel.sh: writes workbooks for Laravel
// Excel to read, and prints what it reads from Laravel Excel's files.
import 'dart:convert';
import 'dart:io';

import 'package:daravel_excel/daravel_excel.dart';

/// The rows both sides write: text with escapes and Unicode, integers,
/// decimals, booleans, empty cells, dates.
final class SampleExport implements FromCollection, WithHeadings, WithTitle {
  @override
  List<Object?> headings() => [
    'Nama',
    'Jumlah',
    'Nilai',
    'Aktif',
    'Catatan',
    'Tanggal',
  ];

  @override
  List<Object?> collection() => [
    ['Ana & "Bo" <x>', 42, 3.25, true, null, DateTime.utc(2026, 10, 28)],
    [
      'ünïcødé 🌴',
      -7,
      0.001,
      false,
      '  spasi  ',
      DateTime.utc(2026, 10, 28, 7, 30),
    ],
    for (var i = 1; i <= 3000; i++)
      ['Baris $i', i, i / 4, i.isEven, null, null],
  ];

  @override
  String title() => 'Laporan';
}

Future<void> main(List<String> args) async {
  final dir = args[1];
  switch (args.first) {
    case 'write':
      for (final type in [ExcelType.xlsx, ExcelType.csv]) {
        final bytes = await Excel.raw(SampleExport(), type);
        File('$dir/from-daravel.${type.name}').writeAsBytesSync(bytes);
      }
      stdout.writeln('written');
    case 'read':
      // A Laravel Excel workbook: its rows by heading, dates as serials.
      final [rows] = await Excel.toArray(
        File('$dir/from-laravel.xlsx').readAsBytesSync(),
        type: ExcelType.xlsx,
        headingRow: true,
      );
      final csv = await Excel.toArray(
        File('$dir/from-laravel.csv').readAsBytesSync(),
        type: ExcelType.csv,
        headingRow: true,
      );
      stdout.writeln(
        jsonEncode({
          'count': rows.length,
          'first': rows.first,
          'last': rows.last,
          'date': ExcelDate.toDateTime(rows.first['tanggal']! as num)
              .toIso8601String(),
          'csv_first': csv.single.first,
        }),
      );
  }
}
