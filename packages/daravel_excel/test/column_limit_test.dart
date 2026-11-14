import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:daravel_excel/daravel_excel.dart';
import 'package:daravel_excel/src/zip.dart';
import 'package:test/test.dart';

/// A cell reference past `XFD` (`ZZZZZ1`, `ZZZZZZ1`) made the reader fill
/// the row with an empty cell per column before it: 786 bytes became
/// twelve million cells and 225 MiB, `ZZZZZZ1` did not finish. Each
/// workbook is read in a child process bounded in time and memory.
void main() {
  // Compiled once: run from source, the child's own compiler took about
  // 600 MiB and hid what the reading cost.
  late String child;
  setUpAll(() async {
    final dir = Directory.systemTemp.createTempSync('daravel_excel_child');
    child = '${dir.path}/xlsx_child${Platform.isWindows ? '.exe' : ''}';
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'test/support/xlsx_child.dart',
      '-o',
      child,
    ]);
    if (compiled.exitCode != 0) {
      throw StateError('${compiled.stdout}${compiled.stderr}');
    }
    addTearDown(() => dir.deleteSync(recursive: true));
  });

  /// The bytes of a one-sheet workbook whose sheet XML is [sheetData].
  Future<Uint8List> workbook(String sheetData) async {
    final base = await Excel.raw(
      ListExport([
        [1],
      ]),
      ExcelType.xlsx,
    );
    final zip = await ZipReader.open(RandomAccessSource.bytes(base));
    final writer = ZipStreamWriter.buffered();
    for (final name in zip.entries.keys) {
      final entry = writer.entry(name);
      if (name == 'xl/worksheets/sheet1.xml') {
        entry.addString(
          '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/'
          'spreadsheetml/2006/main"><sheetData>$sheetData</sheetData>'
          '</worksheet>',
        );
      } else {
        entry.add(await zip.read(name).expand((c) => c).toList());
      }
      entry.close();
    }
    writer.finish();
    return Uint8List.fromList([for (final chunk in writer.take()) ...chunk]);
  }

  /// Reads [bytes] in a child process: its first output line, and its peak
  /// RSS; `hung` when it is still running after [limit].
  Future<(String, int)> read(
    Uint8List bytes, {
    Duration limit = const Duration(seconds: 30),
  }) async {
    final dir = Directory.systemTemp.createTempSync('daravel_excel_bomb');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/book.xlsx')..writeAsBytesSync(bytes);
    final process = await Process.start(child, [file.path]);
    final output = process.stdout.transform(utf8.decoder).join();
    unawaited(process.stderr.drain<void>());
    try {
      await process.exitCode.timeout(limit);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      return ('hung', 0);
    }
    final lines = const LineSplitter().convert(await output);
    final rss = int.parse(lines.last.split(' ').last);
    return (lines.first, rss);
  }

  const mib = 1024 * 1024;

  for (final ref in ['ZZZZZ1', 'ZZZZZZ1', 'XFE1', 'AAAAAAAAAAAAAAAAAAAAAAA1']) {
    test('a cell at $ref is refused, quickly and in bounded memory', () async {
      final bytes = await workbook('<row r="1"><c r="$ref"><v>1</v></c></row>');
      final (line, rss) = await read(bytes);
      expect(line, 'error FormatException');
      expect(rss, lessThan(400 * mib));
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  test('a row of cells without references past XFD is refused', () async {
    final cells = '<c><v>1</v></c>' * (maxColumns + 1);
    final (line, rss) = await read(await workbook('<row r="1">$cells</row>'));
    expect(line, 'error FormatException');
    expect(rss, lessThan(400 * mib));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a full row of 16 384 columns and a lone XFD1 still read', () async {
    final full = StringBuffer('<row r="1">');
    for (var i = 0; i < maxColumns; i++) {
      full.write('<c r="${columnLetter(i)}1"><v>$i</v></c>');
    }
    full.write('</row><row r="2"><c r="XFD2"><v>7</v></c></row>');
    final (line, _) = await read(await workbook(full.toString()));
    expect(line, 'ok 2 $maxColumns');
  }, timeout: const Timeout(Duration(minutes: 2)));
}

final class ListExport implements FromCollection {
  ListExport(this.rows);
  final List<Object?> rows;

  @override
  List<Object?> collection() => rows;
}
