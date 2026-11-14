/// Column letters, Excel dates and number formats.
library;

/// `0` → `A`, `25` → `Z`, `26` → `AA` (zero-based index to letters).
String columnLetter(int index) {
  var n = index + 1;
  final letters = StringBuffer();
  final out = <int>[];
  while (n > 0) {
    final r = (n - 1) % 26;
    out.add(0x41 + r);
    n = (n - 1) ~/ 26;
  }
  for (final c in out.reversed) {
    letters.writeCharCode(c);
  }
  return letters.toString();
}

/// The number of columns a worksheet holds (`A` to `XFD`), the limit of
/// the file format (ECMA-376, and Excel's).
const int maxColumns = 16384;

/// `A` → `0`, `AA` → `26` (letters to zero-based index), ignoring case.
///
/// A column past `XFD` (index 16 383) is a [FormatException]: no workbook
/// holds one, and a reader that took `ZZZZZZ1` at its word filled a row
/// with hundreds of millions of empty cells before the first value.
int columnIndex(String letters) {
  if (letters.isEmpty) {
    // It used to answer -1.
    throw const FormatException('Not a column: no letters');
  }
  var n = 0;
  for (final unit in letters.toUpperCase().codeUnits) {
    if (unit < 0x41 || unit > 0x5A) {
      throw FormatException('Not a column: ${_quoted(letters)}');
    }
    n = n * 26 + (unit - 0x40);
    if (n > maxColumns) {
      throw FormatException(
        'Column ${_quoted(letters)} is past XFD, the last of the $maxColumns '
        'columns a worksheet holds.',
      );
    }
  }
  return n - 1;
}

/// [letters] for a message, at most 16 characters: a reference of a
/// megabyte of letters must not become a megabyte of log line.
String _quoted(String letters) =>
    letters.length <= 16 ? letters : '${letters.substring(0, 16)}…';

/// Excel's serial dates (the 1900 system, with its phantom 29 February
/// 1900): what a date cell holds.
abstract final class ExcelDate {
  static final DateTime _epoch = DateTime.utc(1899, 12, 30);

  /// [value] as an Excel serial number (days since 1899-12-30, the time
  /// as a fraction), read in UTC.
  static double fromDateTime(DateTime value) {
    final utc = value.isUtc
        ? value
        : DateTime.utc(
            value.year,
            value.month,
            value.day,
            value.hour,
            value.minute,
            value.second,
            value.millisecond,
            value.microsecond,
          );
    var days =
        utc.difference(_epoch).inMicroseconds / Duration.microsecondsPerDay;
    // Serial 60 is 1900-02-29, which never existed: dates before March
    // 1900 are one lower.
    if (days < 61) {
      days -= 1;
    }
    return days;
  }

  /// The date of the serial [value] (`Date::excelToDateTimeObject`), in
  /// UTC.
  static DateTime toDateTime(num value) {
    var days = value.toDouble();
    if (days < 60) {
      days += 1;
    }
    final micros = (days * Duration.microsecondsPerDay).round();
    return _epoch.add(Duration(microseconds: micros));
  }
}

/// Number format codes (PhpSpreadsheet's `NumberFormat` constants), for
/// `WithColumnFormatting`.
abstract final class NumberFormat {
  /// Excel's General format.
  static const String general = 'General';

  /// Text: the value as written.
  static const String text = '@';

  /// A whole number.
  static const String number = '0';

  /// A number with two decimals.
  static const String number00 = '0.00';

  /// A number with thousands separators and two decimals.
  static const String numberCommaSeparated1 = '#,##0.00';

  /// As [numberCommaSeparated1], with room for a minus sign.
  static const String numberCommaSeparated2 = '#,##0.00_-';

  /// A whole percentage.
  static const String percentage = '0%';

  /// A percentage with two decimals.
  static const String percentage00 = '0.00%';

  /// A date as `yyyy-mm-dd`.
  static const String dateYyyymmdd = 'yyyy-mm-dd';

  /// A date as `dd/mm/yyyy`.
  static const String dateDdmmyyyy = 'dd/mm/yyyy';

  /// A date and time.
  static const String dateDatetime = 'yyyy-mm-dd hh:mm:ss';

  /// A time of day.
  static const String dateTime3 = 'h:mm:ss';

  /// US dollars.
  static const String currencyUsd = r'[$$-409]#,##0.00';

  /// Euros.
  static const String currencyEur = r'[$€-2]\ #,##0.00';

  /// Indonesian rupiah, without decimals.
  static const String currencyIdr = r'[$Rp-421]\ #,##0';
}
