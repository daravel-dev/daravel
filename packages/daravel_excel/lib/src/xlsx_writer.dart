import 'cells.dart';
import 'zip.dart';

const String _main =
    'http://schemas.openxmlformats.org/spreadsheetml/2006/main';
const String _rel =
    'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const String _xmlHead =
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n';

/// PhpSpreadsheet's longest cell text; longer text is cut, as it does.
const int maxCellLength = 32767;

/// Writes an XLSX workbook one row at a time. Rows go straight into the
/// sheet's deflated ZIP entry; strings are inline (`t="inlineStr"`), so no
/// shared-strings table grows in memory. [take] hands over the bytes
/// written so far.
final class XlsxWriter {
  final ZipStreamWriter _zip = ZipStreamWriter.buffered();
  final List<String> _titles = [];

  /// Number format codes by style index (index 0 is the default style).
  final List<String?> _styleFormats = [null];
  final Map<String, int> _styleOf = {};

  ZipEntrySink? _sheet;
  int _row = 0;
  Map<int, int> _columnStyles = const {};
  final StringBuffer _buffer = StringBuffer();

  /// Bytes written since the last call.
  List<List<int>> take() {
    _flush();
    return _zip.take();
  }

  /// Starts a sheet named [title] (made valid and unique). [formats] are
  /// number format codes by zero-based column, [widths] column widths.
  void startSheet(
    String title, {
    Map<int, String> formats = const {},
    Map<int, double> widths = const {},
  }) {
    if (_sheet != null) {
      endSheet();
    }
    _titles.add(_uniqueTitle(title));
    _sheet = _zip.entry('xl/worksheets/sheet${_titles.length}.xml');
    _row = 0;
    _columnStyles = {
      for (final MapEntry(:key, :value) in formats.entries) key: _style(value),
    };
    _buffer
      ..write(_xmlHead)
      ..write('<worksheet xmlns="$_main" xmlns:r="$_rel">');
    if (widths.isNotEmpty) {
      _buffer.write('<cols>');
      for (final column in widths.keys.toList()..sort()) {
        final n = column + 1;
        _buffer.write(
          '<col min="$n" max="$n" width="${widths[column]}" customWidth="1"/>',
        );
      }
      _buffer.write('</cols>');
    }
    _buffer.write('<sheetData>');
  }

  /// Appends a row: numbers, booleans, dates (as Excel dates), strings;
  /// `null` leaves the cell empty; anything else is written as its text.
  void addRow(List<Object?> cells) {
    if (_sheet == null) {
      startSheet('Worksheet');
    }
    _row++;
    _buffer.write('<row r="$_row">');
    for (var i = 0; i < cells.length; i++) {
      _cell(i, cells[i]);
    }
    _buffer.write('</row>');
    if (_buffer.length > 64 * 1024) {
      _flush();
    }
  }

  void _cell(int column, Object? value) {
    if (value == null) {
      return;
    }
    final ref = '${columnLetter(column)}$_row';
    var style = _columnStyles[column] ?? 0;
    switch (value) {
      case bool():
        _buffer.write(
          '<c r="$ref"${_s(style)} t="b"><v>${value ? 1 : 0}</v></c>',
        );
      case num() when value.isFinite:
        _buffer.write('<c r="$ref"${_s(style)}><v>${_number(value)}</v></c>');
      case num():
        return;
      case DateTime():
        if (style == 0) {
          final midnight =
              value.hour == 0 &&
              value.minute == 0 &&
              value.second == 0 &&
              value.millisecond == 0;
          style = _style(
            midnight ? NumberFormat.dateYyyymmdd : NumberFormat.dateDatetime,
          );
        }
        _buffer.write(
          '<c r="$ref"${_s(style)}><v>${_number(ExcelDate.fromDateTime(value))}</v></c>',
        );
      default:
        var text = value is Enum ? value.name : '$value';
        if (text.length > maxCellLength) {
          text = text.substring(0, maxCellLength);
        }
        final space = text != text.trim() ? ' xml:space="preserve"' : '';
        _buffer.write(
          '<c r="$ref"${_s(style)} t="inlineStr"><is><t$space>${escapeXml(text)}</t></is></c>',
        );
    }
  }

  static String _s(int style) => style == 0 ? '' : ' s="$style"';

  static String _number(num value) {
    if (value is int ||
        value == value.truncateToDouble() && value.abs() < 1e15) {
      return value.toInt().toString();
    }
    return value.toString();
  }

  int _style(String format) => _styleOf.putIfAbsent(format, () {
    _styleFormats.add(format);
    return _styleFormats.length - 1;
  });

  void endSheet() {
    final sheet = _sheet;
    if (sheet == null) {
      return;
    }
    _buffer.write('</sheetData></worksheet>');
    _flush();
    sheet.close();
    _sheet = null;
  }

  void _flush() {
    if (_buffer.isNotEmpty && _sheet != null) {
      _sheet!.addString(_buffer.toString());
      _buffer.clear();
    }
  }

  /// Writes the workbook, its styles and the package parts, then the ZIP
  /// directory.
  void finish() {
    if (_sheet != null) {
      endSheet();
    }
    if (_titles.isEmpty) {
      startSheet('Worksheet');
      endSheet();
    }
    final n = _titles.length;
    _part('[Content_Types].xml', [
      _xmlHead,
      '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">',
      '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>',
      '<Default Extension="xml" ContentType="application/xml"/>',
      '<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>',
      for (var i = 1; i <= n; i++)
        '<Override PartName="/xl/worksheets/sheet$i.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>',
      '<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>',
      '</Types>',
    ]);
    _part('_rels/.rels', [
      _xmlHead,
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
      '<Relationship Id="rId1" Type="$_rel/officeDocument" Target="xl/workbook.xml"/>',
      '</Relationships>',
    ]);
    _part('xl/workbook.xml', [
      _xmlHead,
      '<workbook xmlns="$_main" xmlns:r="$_rel"><sheets>',
      for (var i = 1; i <= n; i++)
        '<sheet name="${escapeXml(_titles[i - 1])}" sheetId="$i" r:id="rId$i"/>',
      '</sheets></workbook>',
    ]);
    _part('xl/_rels/workbook.xml.rels', [
      _xmlHead,
      '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">',
      for (var i = 1; i <= n; i++)
        '<Relationship Id="rId$i" Type="$_rel/worksheet" Target="worksheets/sheet$i.xml"/>',
      '<Relationship Id="rId${n + 1}" Type="$_rel/styles" Target="styles.xml"/>',
      '</Relationships>',
    ]);
    _part('xl/styles.xml', _styles());
    _zip.finish();
  }

  List<String> _styles() {
    final custom = <String, int>{};
    int formatId(String code) =>
        _builtinFormats[code] ??
        custom.putIfAbsent(code, () => 164 + custom.length);
    final xfs = [
      for (final format in _styleFormats)
        format == null
            ? '<xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>'
            : '<xf numFmtId="${formatId(format)}" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>',
    ];
    return [
      _xmlHead,
      '<styleSheet xmlns="$_main">',
      if (custom.isNotEmpty) ...[
        '<numFmts count="${custom.length}">',
        for (final MapEntry(:key, :value) in custom.entries)
          '<numFmt numFmtId="$value" formatCode="${escapeXml(key)}"/>',
        '</numFmts>',
      ],
      '<fonts count="1"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>',
      '<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>',
      '<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>',
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>',
      '<cellXfs count="${xfs.length}">',
      ...xfs,
      '</cellXfs>',
      '<cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>',
      '</styleSheet>',
    ];
  }

  void _part(String name, List<String> content) {
    final entry = _zip.entry(name);
    entry.addString(content.join());
    entry.close();
  }

  String _uniqueTitle(String title) {
    var clean = title.replaceAll(RegExp(r'[\[\]:*?/\\]'), '').trim();
    if (clean.isEmpty) {
      clean = 'Worksheet';
    }
    if (clean.length > 31) {
      clean = clean.substring(0, 31);
    }
    var candidate = clean;
    for (
      var i = 1;
      _titles.any((t) => t.toLowerCase() == candidate.toLowerCase());
      i++
    ) {
      final suffix = ' $i';
      candidate =
          '${clean.length + suffix.length > 31 ? clean.substring(0, 31 - suffix.length) : clean}$suffix';
    }
    return candidate;
  }

  static const Map<String, int> _builtinFormats = {
    'General': 0,
    '0': 1,
    '0.00': 2,
    '#,##0': 3,
    '#,##0.00': 4,
    '0%': 9,
    '0.00%': 10,
    '@': 49,
  };
}

/// [text] escaped for XML content and attributes, without the control
/// characters XML 1.0 forbids (they would make the file unreadable).
String escapeXml(String text) {
  final buffer = StringBuffer();
  for (final unit in text.codeUnits) {
    switch (unit) {
      case 0x26:
        buffer.write('&amp;');
      case 0x3C:
        buffer.write('&lt;');
      case 0x3E:
        buffer.write('&gt;');
      case 0x22:
        buffer.write('&quot;');
      case 0x09 || 0x0A || 0x0D:
        buffer.writeCharCode(unit);
      case < 0x20 || 0xFFFE || 0xFFFF:
        break;
      default:
        buffer.writeCharCode(unit);
    }
  }
  return buffer.toString();
}
