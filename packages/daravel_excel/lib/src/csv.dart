import 'dart:async';
import 'dart:convert';

/// CSV settings (Laravel Excel's `excel.exports.csv` and
/// `excel.imports.csv`), for `WithCustomCsvSettings`.
final class CsvSettings {
  const CsvSettings({
    this.delimiter,
    this.enclosure = '"',
    this.lineEnding = '\n',
    this.useBom = false,
    this.inputEncoding = 'UTF-8',
  });

  /// The field separator: `,` when writing; detected among `,`, `;`, tab
  /// and `|` from the first line when reading, unless set.
  final String? delimiter;

  /// Wraps every written field, as PhpSpreadsheet's writer does.
  final String enclosure;
  final String lineEnding;

  /// Starts a written file with the UTF-8 byte order mark (Excel on
  /// Windows needs it to read UTF-8).
  final bool useBom;

  /// `UTF-8` or `ISO-8859-1` (Latin-1) for reading.
  final String inputEncoding;

  /// Tab-separated values.
  static const CsvSettings tsv = CsvSettings(delimiter: '\t');
}

/// One CSV line for [row], every field enclosed, as PhpSpreadsheet's CSV
/// writer writes it.
String csvLine(List<String> row, CsvSettings settings) {
  final delimiter = settings.delimiter ?? ',';
  final q = settings.enclosure;
  final buffer = StringBuffer();
  for (var i = 0; i < row.length; i++) {
    if (i > 0) {
      buffer.write(delimiter);
    }
    if (q.isEmpty) {
      buffer.write(row[i]);
    } else {
      buffer
        ..write(q)
        ..write(row[i].replaceAll(q, '$q$q'))
        ..write(q);
    }
  }
  buffer.write(settings.lineEnding);
  return buffer.toString();
}

/// Parses CSV text arriving in chunks into rows of strings: quoted fields
/// with doubled quotes, line breaks inside quotes, `\r\n`, `\n` or `\r`
/// endings, and a leading byte order mark.
Stream<List<String>> parseCsv(
  Stream<List<int>> bytes,
  CsvSettings settings,
) async* {
  final decoder = settings.inputEncoding.toUpperCase() == 'UTF-8'
      ? const Utf8Decoder(allowMalformed: true)
      : const Latin1Decoder(allowInvalid: true);
  final q = settings.enclosure.isEmpty ? -1 : settings.enclosure.codeUnitAt(0);
  int? delimiter = settings.delimiter?.codeUnitAt(0);
  var field = StringBuffer();
  var row = <String>[];
  var quoted = false;
  var afterQuote = false;
  var first = true;
  var pendingCr = false;
  final rows = <List<String>>[];

  void endField() {
    row.add(field.toString());
    field = StringBuffer();
    afterQuote = false;
  }

  void endRow() {
    endField();
    rows.add(row);
    row = <String>[];
  }

  await for (var text in decoder.bind(bytes)) {
    if (first) {
      if (text.isEmpty) {
        continue;
      }
      first = false;
      if (text.codeUnitAt(0) == 0xFEFF) {
        text = text.substring(1);
      }
      delimiter ??= _detect(text);
    }
    for (final c in text.codeUnits) {
      if (pendingCr) {
        pendingCr = false;
        if (c == 0x0A) {
          continue;
        }
      }
      if (quoted) {
        if (c == q) {
          quoted = false;
          afterQuote = true;
        } else {
          field.writeCharCode(c);
        }
        continue;
      }
      if (c == q) {
        if (afterQuote) {
          // A doubled quote inside a quoted field.
          field.writeCharCode(c);
        }
        quoted = true;
        afterQuote = false;
      } else if (c == delimiter) {
        endField();
      } else if (c == 0x0A || c == 0x0D) {
        endRow();
        pendingCr = c == 0x0D;
      } else {
        field.writeCharCode(c);
      }
    }
    for (final done in rows) {
      yield done;
    }
    rows.clear();
  }
  if (field.isNotEmpty || row.isNotEmpty || afterQuote) {
    endRow();
    yield* Stream.fromIterable(rows);
  }
}

int _detect(String text) {
  final line = text.split(RegExp('[\r\n]')).first;
  var best = 0x2C;
  var count = -1;
  for (final candidate in const [0x2C, 0x3B, 0x09, 0x7C]) {
    final n = line.codeUnits.where((c) => c == candidate).length;
    if (n > count) {
      best = candidate;
      count = n;
    }
  }
  return best;
}
